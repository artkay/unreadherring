defmodule UnreadHerring.Scanner do
  @moduledoc """
  GenServer owning a scan and its aggregated result.

  ## Contract

  - `start_link(opts)` - `:name` (default `__MODULE__`) and `:cache_path`
    (default `UnreadHerring.Config.path("last_scan.json")`, resolved lazily
    in `init/1`). Loads the persisted last-scan cache on init; a corrupt or
    missing file simply means `:empty`.
  - `subscribe()` - subscribe the caller to PubSub topic `"scan"` on
    `UnreadHerring.PubSub`.
  - `scan(opts)` - async (cast). `opts`: `%{group_by: :domain | :sender |
    :label, scope: :unread | :all, inbox: boolean, window: :d30 | :d90 |
    :y1 | :all, max: pos_integer}` (defaults: `:domain`, `:unread`,
    `true`, `:all`, and the `:scan_max` app env - 10,000 unless
    overridden via `HERRING_SCAN_MAX`). `inbox: true` restricts the scan
    to the Inbox, matching what Gmail's sidebar badge counts.
    Spawns a supervised task under `UnreadHerring.Tasks` that lists ids,
    fetches metadata, aggregates, broadcasting over PubSub topic "scan":
      `{:scan_started, total_estimate}`
      `{:progress, n, total}`             (during metadata fetch)
      `{:scan_incomplete, dropped, total}` (some metadata fetches were
                                           dropped, typically Gmail
                                           rate limiting)
      `{:done, tree}`                     (tree from UnreadHerring.Aggregate)
      `{:scan_error, reason}`
    A scan requested while one is already running is ignored.
  - `last_result()` -> `{:ok, %{tree: tree, opts: opts, scanned_at: dt}}`
    | `:empty` - cached so drill-down and actions don't rescan. Successful
    scans are also persisted to the cache path so the last result survives
    restarts.
  - `clear()` - forgets the cached last scan and deletes the on-disk
    cache file (the UI "Reset" control).
  - `apply_action(query, action)` - async; `action` is `:mark_read`, the
    only bulk action (it removes the UNREAD label and nothing else).
    Lists ids for `query`, then `Gmail.batch_modify`; broadcasts
    `{:action_done, action, count}` or `{:action_error, action, reason}`.
    Actions run independently of scans and of each other.

  Every Gmail call additionally merges the
  `Application.get_env(:unread_herring, :scanner_gmail_opts, [])` options,
  which tests use to inject a token and `Req.Test` plug.
  """

  use GenServer

  require Logger

  alias UnreadHerring.{Aggregate, Config, Gmail}

  @topic "scan"
  @progress_every 10
  @action_max_ids 10_000

  @default_opts %{group_by: :domain, scope: :unread, inbox: true, window: :all}
  @allowed %{
    group_by: [:domain, :sender, :label],
    scope: [:unread, :all],
    window: [:d30, :d90, :y1, :all]
  }
  @actions [:mark_read]

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Subscribes the caller to the \"scan\" PubSub topic."
  def subscribe do
    Phoenix.PubSub.subscribe(UnreadHerring.PubSub, @topic)
  end

  @doc "Starts a scan asynchronously. See the module doc for `opts`."
  def scan(server \\ __MODULE__, opts) do
    GenServer.cast(server, {:scan, opts})
  end

  @doc "Returns the cached last scan, or `:empty`."
  def last_result(server \\ __MODULE__) do
    GenServer.call(server, :last_result)
  end

  @doc "Forgets the cached last scan and deletes the on-disk cache file."
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  @doc "Applies `action` to every message matching `query`, asynchronously."
  def apply_action(server \\ __MODULE__, query, action) when action in @actions do
    GenServer.cast(server, {:apply_action, query, action})
  end

  @doc "Maximum number of messages a single bulk action will touch."
  def action_max_ids, do: @action_max_ids

  ## Server callbacks

  @impl true
  def init(opts) do
    cache_path =
      Keyword.get_lazy(opts, :cache_path, fn -> Config.path("last_scan.json") end)

    {:ok,
     %{
       running: nil,
       actions: %{},
       last: load_cache(cache_path),
       cache_path: cache_path
     }}
  end

  @impl true
  def handle_cast({:scan, _opts}, %{running: running} = state) when not is_nil(running) do
    Logger.info("Scan requested while another scan is running; ignoring")
    {:noreply, state}
  end

  def handle_cast({:scan, opts}, state) do
    opts = normalize_opts(opts)
    task = Task.Supervisor.async_nolink(UnreadHerring.Tasks, fn -> run_scan(opts) end)
    {:noreply, %{state | running: %{ref: task.ref, opts: opts}}}
  end

  def handle_cast({:apply_action, query, action}, state) do
    task = Task.Supervisor.async_nolink(UnreadHerring.Tasks, fn -> run_action(query, action) end)
    {:noreply, %{state | actions: Map.put(state.actions, task.ref, action)}}
  end

  @impl true
  def handle_call(:last_result, _from, state) do
    reply = if state.last, do: {:ok, state.last}, else: :empty
    {:reply, reply, state}
  end

  def handle_call(:clear, _from, state) do
    File.rm(state.cache_path)
    {:reply, :ok, %{state | last: nil}}
  end

  @impl true
  def handle_info({ref, result}, %{running: %{ref: ref, opts: opts}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:done, tree, email} ->
          last = %{tree: tree, opts: opts, scanned_at: DateTime.utc_now(), email: email}
          persist_cache(state.cache_path, last)
          broadcast({:done, tree})
          %{state | last: last}

        {:scan_error, reason} ->
          broadcast({:scan_error, reason})
          state
      end

    {:noreply, %{state | running: nil}}
  end

  def handle_info({ref, result}, state) when is_map_key(state.actions, ref) do
    Process.demonitor(ref, [:flush])
    broadcast(result)
    {:noreply, %{state | actions: Map.delete(state.actions, ref)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref}} = state) do
    Logger.warning("Scan task crashed: #{inspect(reason)}")
    broadcast({:scan_error, reason})
    {:noreply, %{state | running: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when is_map_key(state.actions, ref) do
    {action, actions} = Map.pop(state.actions, ref)
    Logger.warning("Action task (#{action}) crashed: #{inspect(reason)}")
    broadcast({:action_error, action, reason})
    {:noreply, %{state | actions: actions}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Scan task

  defp run_scan(opts) do
    query = Aggregate.base_query(opts)

    with {:ok, labels} <- fetch_labels(opts),
         {:ok, ids} <- Gmail.list_message_ids(query, gmail_opts(max: opts.max)) do
      total = length(ids)
      broadcast({:scan_started, total})

      counter = :counters.new(1, [])

      on_each = fn _result ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        if rem(n, @progress_every) == 0 or n == total do
          broadcast({:progress, n, total})
        end
      end

      case Gmail.fetch_metadata(ids, gmail_opts(on_each: on_each)) do
        {:ok, messages} ->
          # Metadata fetches that kept failing after retries (typically
          # Gmail per-minute rate limiting) are dropped from the result;
          # tell the UI so the chart is not silently incomplete.
          dropped = total - length(messages)
          if dropped > 0, do: broadcast({:scan_incomplete, dropped, total})

          {:done, Aggregate.build_tree(messages, Map.put(opts, :labels, labels)), fetch_email()}

        {:error, reason} ->
          {:scan_error, reason}
      end
    else
      {:error, reason} -> {:scan_error, reason}
    end
  end

  # The account email lets the UI build Gmail links that open the right
  # account when several are logged in. Best effort - nil on failure.
  defp fetch_email do
    case Gmail.get_profile(gmail_opts([])) do
      {:ok, %{email_address: email}} -> email
      {:error, _reason} -> nil
    end
  end

  defp fetch_labels(%{group_by: :label}) do
    case Gmail.list_labels(gmail_opts([])) do
      {:ok, labels} ->
        {:ok, for(%{type: "user", id: id, name: name} <- labels, into: %{}, do: {id, name})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_labels(_opts), do: {:ok, %{}}

  ## Action task

  defp run_action(query, action) do
    with {:ok, ids} <- Gmail.list_message_ids(query, gmail_opts(max: @action_max_ids)),
         :ok <- Gmail.batch_modify(ids, gmail_opts(action_label_opts(action))) do
      # When the listing hits the cap there may be more matches we did not
      # touch; report the count as a lower bound so the UI can say so.
      count = length(ids)
      count = if count == @action_max_ids, do: {:at_least, count}, else: count
      {:action_done, action, count}
    else
      {:error, reason} -> {:action_error, action, reason}
    end
  end

  # Mark-read removes the UNREAD label and nothing else; no destructive
  # code path exists anywhere in this module - by design.
  defp action_label_opts(:mark_read), do: [remove_label_ids: ["UNREAD"]]

  ## Helpers

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(UnreadHerring.PubSub, @topic, message)
  end

  defp gmail_opts(opts) do
    Keyword.merge(opts, Application.get_env(:unread_herring, :scanner_gmail_opts, []))
  end

  defp normalize_opts(opts) do
    opts = Map.new(opts)

    %{
      group_by: pick(opts, :group_by),
      scope: pick(opts, :scope),
      inbox: normalize_inbox(Map.get(opts, :inbox)),
      window: pick(opts, :window),
      max: normalize_max(Map.get(opts, :max))
    }
  end

  defp normalize_inbox(inbox) when is_boolean(inbox), do: inbox
  defp normalize_inbox(_inbox), do: @default_opts.inbox

  defp pick(opts, key) do
    value = Map.get(opts, key)
    if value in Map.fetch!(@allowed, key), do: value, else: Map.fetch!(@default_opts, key)
  end

  defp normalize_max(max) when is_integer(max) and max > 0, do: max
  defp normalize_max(_max), do: Application.get_env(:unread_herring, :scan_max, 10_000)

  ## Last-scan disk cache

  defp persist_cache(path, last) do
    payload = %{
      tree: last.tree,
      opts: last.opts,
      scanned_at: DateTime.to_iso8601(last.scanned_at),
      email: last.email
    }

    File.mkdir_p(Path.dirname(path))

    # Mailbox metadata: lock the file down before any content lands in it,
    # same treatment as the token file.
    with :ok <- File.touch(path),
         :ok <- File.chmod(path, 0o600),
         :ok <- File.write(path, Jason.encode!(payload)) do
      :ok
    else
      {:error, reason} -> Logger.warning("Could not persist last-scan cache: #{inspect(reason)}")
    end
  end

  defp load_cache(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
         {:ok, last} <- decode_cache(decoded) do
      last
    else
      _ -> nil
    end
  end

  defp decode_cache(%{"tree" => tree, "opts" => opts, "scanned_at" => scanned_at} = decoded) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(scanned_at) do
      {:ok,
       %{
         tree: decode_node(tree),
         opts: decode_opts(opts),
         scanned_at: dt,
         email: Map.get(decoded, "email")
       }}
    end
  rescue
    _ -> :error
  end

  defp decode_cache(_decoded), do: :error

  defp decode_node(node) do
    %{
      id: Map.fetch!(node, "id"),
      label: Map.fetch!(node, "label"),
      count: Map.fetch!(node, "count"),
      query: Map.fetch!(node, "query"),
      children: node |> Map.fetch!("children") |> Enum.map(&decode_node/1)
    }
  end

  defp decode_opts(opts) do
    %{
      group_by: opts |> Map.fetch!("group_by") |> String.to_existing_atom(),
      scope: opts |> Map.fetch!("scope") |> String.to_existing_atom(),
      # Caches written before the inbox toggle existed scanned everything.
      inbox: Map.get(opts, "inbox", false),
      window: opts |> Map.fetch!("window") |> String.to_existing_atom(),
      max: Map.fetch!(opts, "max")
    }
  end
end
