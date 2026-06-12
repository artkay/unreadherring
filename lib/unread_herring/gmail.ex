defmodule UnreadHerring.Gmail do
  @moduledoc """
  Thin Req client for the Gmail REST API (`users/me` only).

  All functions accept a trailing keyword list of options:

  - `:token` - OAuth access token. When absent, the token is fetched from
    `UnreadHerring.Auth.TokenStore.get_access_token/0` and
    `{:error, :not_authenticated}` is propagated when there is none.
  - `:req_options` - extra Req options merged into every request. Tests use
    this (together with the `:gmail_req_options` application env) to inject
    `plug: {Req.Test, UnreadHerring.Gmail}` and disable retries.

  Requests retry transient failures (429, 5xx, and Gmail's 403-flavored
  rate limiting) up to 5 times with exponential backoff by default.
  """

  require Logger

  @base_url "https://gmail.googleapis.com/gmail/v1/users/me"
  @page_size 500
  @default_max_concurrency 15
  @batch_modify_chunk 1000
  @metadata_timeout 30_000

  @doc """
  Lists message ids matching the Gmail search `query`.

  Paginates `GET /messages` (500 per page) until exhausted or until
  `opts[:max]` ids have been collected (default: the `:scan_max` app env,
  10,000 unless overridden via `HERRING_SCAN_MAX`); the result is
  truncated to that cap. An empty mailbox yields `{:ok, []}`.

  Options: `:max`, `:on_page` (arity-1 callback receiving the running id
  count after each page), plus the common `:token` / `:req_options`.
  """
  @spec list_message_ids(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_message_ids(query, opts \\ []) do
    with {:ok, token} <- resolve_token(opts) do
      req = build_req(token, opts)

      max =
        Keyword.get_lazy(opts, :max, fn ->
          Application.get_env(:unread_herring, :scan_max, 10_000)
        end)

      on_page = Keyword.get(opts, :on_page)
      list_pages(req, query, nil, [], 0, max, on_page)
    end
  end

  defp list_pages(req, query, page_token, acc, count, max, on_page) do
    params =
      [q: query, maxResults: @page_size] ++
        if page_token, do: [pageToken: page_token], else: []

    case Req.get(req, url: "/messages", params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        ids = body |> Map.get("messages", []) |> Enum.map(& &1["id"])
        count = min(count + length(ids), max)
        if on_page, do: on_page.(count)
        acc = [acc | ids]
        next_token = body["nextPageToken"]

        if count >= max or is_nil(next_token) do
          {:ok, acc |> List.flatten() |> Enum.take(max)}
        else
          list_pages(req, query, next_token, acc, count, max, on_page)
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches metadata for each message id concurrently.

  Returns `{:ok, messages}` where each message is
  `%{id: id, from: from | nil, label_ids: [label_id]}`. Per-message failures
  (HTTP errors, timeouts) are logged and dropped, so the result list may be
  shorter than `ids`. Ordering is not preserved.

  Options: `:max_concurrency` (default #{@default_max_concurrency}),
  `:on_each` (arity-1 callback invoked once per completed message, success or
  drop), plus the common `:token` / `:req_options`.
  """
  @spec fetch_metadata([String.t()], keyword()) ::
          {:ok, [%{id: String.t(), from: String.t() | nil, label_ids: [String.t()]}]}
          | {:error, :not_authenticated}
          | {:error, term()}
  def fetch_metadata(ids, opts \\ []) do
    with {:ok, token} <- resolve_token(opts) do
      req = build_req(token, opts)
      max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)
      on_each = Keyword.get(opts, :on_each)

      messages =
        UnreadHerring.Tasks
        |> Task.Supervisor.async_stream_nolink(ids, &fetch_one(req, &1),
          max_concurrency: max_concurrency,
          ordered: false,
          timeout: @metadata_timeout,
          on_timeout: :kill_task
        )
        |> Enum.reduce([], fn result, acc ->
          if on_each, do: on_each.(result)

          case result do
            {:ok, {:ok, message}} ->
              [message | acc]

            {:ok, {:error, reason}} ->
              Logger.warning("Gmail metadata fetch failed: #{inspect(reason)}")
              acc

            {:exit, reason} ->
              Logger.warning("Gmail metadata task exited: #{inspect(reason)}")
              acc
          end
        end)

      {:ok, messages}
    end
  end

  defp fetch_one(req, id) do
    case Req.get(req,
           url: "/messages/:id",
           path_params: [id: id],
           params: [format: "metadata", metadataHeaders: "From"]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok,
         %{
           id: id,
           from: extract_from_header(body),
           label_ids: Map.get(body, "labelIds", [])
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {id, {:http_error, status, body}}}

      {:error, reason} ->
        {:error, {id, reason}}
    end
  end

  defp extract_from_header(body) do
    body
    |> get_in(["payload", "headers"])
    |> List.wrap()
    |> Enum.find_value(fn header ->
      if is_binary(header["name"]) and String.downcase(header["name"]) == "from" do
        header["value"]
      end
    end)
  end

  @doc """
  Modifies labels on messages via `POST /messages/batchModify`.

  Ids are chunked into groups of #{@batch_modify_chunk} (the API maximum),
  one call per chunk, stopping on the first error.

  Options: `:add_label_ids`, `:remove_label_ids` (lists, default `[]`), plus
  the common `:token` / `:req_options`.
  """
  @spec batch_modify([String.t()], keyword()) :: :ok | {:error, term()}
  def batch_modify(ids, opts \\ []) do
    add_label_ids = Keyword.get(opts, :add_label_ids, [])
    remove_label_ids = Keyword.get(opts, :remove_label_ids, [])

    with {:ok, token} <- resolve_token(opts) do
      req = build_req(token, opts)

      ids
      |> Enum.chunk_every(@batch_modify_chunk)
      |> Enum.reduce_while(:ok, fn chunk, :ok ->
        body = %{
          "ids" => chunk,
          "addLabelIds" => add_label_ids,
          "removeLabelIds" => remove_label_ids
        }

        case Req.post(req, url: "/messages/batchModify", json: body) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            {:cont, :ok}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:halt, {:error, {:http_error, status, body}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc """
  Lists the mailbox labels via `GET /labels`.

  Returns `{:ok, labels}` where each label is `%{id:, name:, type:}`.
  """
  @spec list_labels(keyword()) ::
          {:ok, [%{id: String.t(), name: String.t(), type: String.t()}]} | {:error, term()}
  def list_labels(opts \\ []) do
    with {:ok, token} <- resolve_token(opts) do
      case Req.get(build_req(token, opts), url: "/labels") do
        {:ok, %Req.Response{status: 200, body: body}} ->
          labels =
            body
            |> Map.get("labels", [])
            |> Enum.map(&%{id: &1["id"], name: &1["name"], type: &1["type"]})

          {:ok, labels}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Fetches the authenticated user's profile via `GET /profile`.

  Returns `{:ok, %{email_address: ...}}` - used to build Gmail deep links
  that land on the right account when several are logged in.
  """
  @spec get_profile(keyword()) :: {:ok, %{email_address: String.t() | nil}} | {:error, term()}
  def get_profile(opts \\ []) do
    with {:ok, token} <- resolve_token(opts) do
      case Req.get(build_req(token, opts), url: "/profile") do
        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, %{email_address: body["emailAddress"]}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_token(opts) do
    case Keyword.fetch(opts, :token) do
      {:ok, token} -> {:ok, token}
      :error -> UnreadHerring.Auth.TokenStore.get_access_token()
    end
  end

  defp build_req(token, opts) do
    [
      base_url: @base_url,
      auth: {:bearer, token},
      retry: &retry?/2,
      retry_delay: &retry_delay/1,
      max_retries: 5
    ]
    |> Keyword.merge(Application.get_env(:unread_herring, :gmail_req_options, []))
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.new()
  end

  # Gmail signals per-user rate limiting with a 403 + "rateLimitExceeded"
  # (not 429), which Req's :transient retry does not cover - so without
  # this, big scans hammer the API and silently drop messages.
  defp retry?(_request, %Req.Response{status: 403} = response), do: rate_limited?(response)

  defp retry?(_request, %Req.Response{status: status}),
    do: status in [408, 429, 500, 502, 503, 504]

  defp retry?(_request, %Req.TransportError{}), do: true
  defp retry?(_request, _other), do: false

  defp rate_limited?(%Req.Response{body: body}) when is_map(body) do
    reasons =
      body
      |> get_in(["error", "errors", Access.all(), "reason"])
      |> List.wrap()

    "rateLimitExceeded" in reasons or "userRateLimitExceeded" in reasons
  end

  defp rate_limited?(%Req.Response{body: body}) when is_binary(body) do
    body =~ "rateLimitExceeded"
  end

  defp rate_limited?(_response), do: false

  # The rate-limit window is per minute, so back off long enough to let it
  # refill: ~1s, 2s, 4s, 8s, 16s (plus jitter), capped at 30s.
  defp retry_delay(attempt) do
    base = min(1000 * Integer.pow(2, attempt), 30_000)
    base + :rand.uniform(500)
  end
end
