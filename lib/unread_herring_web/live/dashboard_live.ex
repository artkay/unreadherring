defmodule UnreadHerringWeb.DashboardLive do
  @moduledoc """
  The dashboard: scan controls, live progress, the server-rendered SVG
  sunburst with drill-down and breadcrumbs, a side panel with the focused
  bucket's children, "Open in Gmail" links, and bulk actions
  (mark-read / archive / trash). Every action is gated by a confirm modal,
  and acted-on buckets stay grayed out until the next scan.
  """

  use UnreadHerringWeb, :live_view

  alias UnreadHerring.{Aggregate, Scanner, Sunburst}
  alias UnreadHerring.Auth.TokenStore

  @default_params %{
    "group_by" => "domain",
    "scope" => "unread",
    "inbox" => "true",
    "window" => "all"
  }

  # Ceiling for the per-scan cap input. Gmail has no hard API limit here,
  # but at one metadata request per message (~50/sec of per-user quota)
  # 100k messages already means a scan of over half an hour.
  @scan_hard_limit 100_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Scanner.subscribe()

    socket =
      socket
      |> assign(
        page_title: "Unread Herring",
        auth_status: TokenStore.status(),
        form: to_form(default_params(), as: "scan"),
        scanning?: false,
        progress: nil,
        tree: nil,
        current_root_id: "root",
        pending_action: nil,
        acted: %{},
        undo_offer: nil,
        last_action_target: nil,
        confirming_logout?: false,
        user_email: nil,
        last_scanned_at: nil,
        last_scan_max: nil
      )
      |> load_last_result()
      |> assign_derived()

    {:ok, socket}
  end

  # The drill-down position lives in the URL (`?node=...`), so a refresh
  # or a shared link lands on the same wedge. An unknown or stale node id
  # (e.g. after the tree changed) falls back to the root.
  @impl true
  def handle_params(params, _uri, socket) do
    node_id =
      case {socket.assigns.tree, params["node"]} do
        {nil, _node} -> "root"
        {_tree, nil} -> "root"
        {tree, node} -> if Aggregate.find_node(tree, node), do: node, else: "root"
      end

    {:noreply, socket |> assign(current_root_id: node_id) |> assign_derived()}
  end

  defp node_path("root"), do: ~p"/"
  defp node_path(node_id), do: ~p"/?#{[node: node_id]}"

  ## Events

  @impl true
  def handle_event("scan", %{"scan" => params}, socket) do
    opts = scan_opts(params)
    Scanner.scan(opts)

    {:noreply,
     socket
     |> assign(
       form: to_form(params, as: "scan"),
       scanning?: true,
       progress: nil,
       last_scan_max: opts.max
     )}
  end

  def handle_event("drill", %{"node-id" => node_id}, socket) do
    case socket.assigns.tree && Aggregate.find_node(socket.assigns.tree, node_id) do
      %{children: [_ | _]} ->
        {:noreply, push_patch(socket, to: node_path(node_id))}

      _leaf_or_missing ->
        {:noreply, socket}
    end
  end

  def handle_event("up", _params, socket) do
    %{tree: tree, current_root_id: current} = socket.assigns

    parent_id =
      case tree && Aggregate.path_to(tree, current) do
        [_ | _] = path when length(path) >= 2 ->
          path |> Enum.at(-2) |> Map.fetch!(:id)

        _root_or_missing ->
          current
      end

    if parent_id == current do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: node_path(parent_id))}
    end
  end

  def handle_event("breadcrumb", %{"node-id" => node_id}, socket) do
    {:noreply, push_patch(socket, to: node_path(node_id))}
  end

  def handle_event("request_action", %{"action" => action}, socket) do
    # Every action goes through the confirm modal. Capture the target at
    # click time: a re-scan can re-root the chart while the modal is open,
    # and the action must still apply to the wedge the user clicked.
    case {parse_action(action), socket.assigns.focused} do
      {nil, _focused} ->
        {:noreply, socket}

      {_action, focused} when is_nil(focused) or is_nil(focused.query) ->
        {:noreply, socket}

      {action, focused} ->
        if acted_entry(socket.assigns.acted, focused.id) do
          # Already acted on (directly or via an ancestor) - nothing to do.
          {:noreply, socket}
        else
          target = %{
            action: action,
            node_id: focused.id,
            label: focused.label,
            count: focused.count,
            query: focused.query
          }

          {:noreply, assign(socket, pending_action: target)}
        end
    end
  end

  def handle_event("confirm_action", _params, socket) do
    case socket.assigns.pending_action do
      %{node_id: "root"} = target when not is_map_key(target, :stage) ->
        # Acting on the whole scan result (not a drilled-down wedge) takes
        # a second, starker confirmation.
        {:noreply, assign(socket, pending_action: Map.put(target, :stage, :final))}

      %{action: action, query: query, node_id: node_id, label: label} ->
        Scanner.apply_action(query, action)
        acted = Map.put(socket.assigns.acted, node_id, %{action: action, status: :pending})

        {:noreply,
         socket
         |> assign(
           pending_action: nil,
           acted: acted,
           last_action_target: %{action: action, node_id: node_id, label: label}
         )
         |> assign_derived()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_action", _params, socket) do
    {:noreply, assign(socket, pending_action: nil)}
  end

  def handle_event("undo", _params, socket) do
    case socket.assigns.undo_offer do
      %{status: :ready} = offer ->
        Scanner.undo_last_action()
        {:noreply, assign(socket, undo_offer: %{offer | status: :undoing})}

      _none_or_in_flight ->
        {:noreply, socket}
    end
  end

  def handle_event("reset", _params, socket) do
    Scanner.clear()
    {:noreply, reset_state(socket)}
  end

  def handle_event("request_logout", _params, socket) do
    {:noreply, assign(socket, confirming_logout?: true)}
  end

  def handle_event("cancel_logout", _params, socket) do
    {:noreply, assign(socket, confirming_logout?: false)}
  end

  def handle_event("confirm_logout", _params, socket) do
    # Revokes the grant at Google (best effort) and deletes the stored token
    # and local scan cache; the user must re-run the OAuth flow next time.
    result = TokenStore.disconnect()
    Scanner.clear()

    flash =
      case result do
        :revoked ->
          "Disconnected: the authorization was revoked at Google and the local token deleted."

        :cleared ->
          "Disconnected and local token deleted, but Google could not be reached to " <>
            "revoke the authorization - you can revoke it manually at " <>
            "myaccount.google.com/permissions."
      end

    {:noreply,
     socket
     |> reset_state()
     |> assign(auth_status: :unauthenticated)
     |> put_flash(:info, flash)}
  end

  defp reset_state(socket) do
    socket
    |> assign(
      form: to_form(default_params(), as: "scan"),
      scanning?: false,
      progress: nil,
      tree: nil,
      current_root_id: "root",
      pending_action: nil,
      acted: %{},
      undo_offer: nil,
      last_action_target: nil,
      confirming_logout?: false,
      user_email: nil,
      last_scanned_at: nil,
      last_scan_max: nil
    )
    |> assign_derived()
    |> push_patch(to: ~p"/")
  end

  ## Scanner PubSub messages

  @impl true
  def handle_info({:scan_started, total}, socket) do
    {:noreply, assign(socket, scanning?: true, progress: {0, total})}
  end

  def handle_info({:progress, n, total}, socket) do
    {:noreply, assign(socket, scanning?: true, progress: {n, total})}
  end

  def handle_info({:done, tree}, socket) do
    # The Scanner caches the account email alongside the result (it has
    # committed its state before broadcasting, so this read is current).
    user_email =
      case Scanner.last_result() do
        {:ok, last} -> Map.get(last, :email)
        :empty -> socket.assigns.user_email
      end

    {:noreply,
     socket
     |> assign(
       tree: tree,
       user_email: user_email,
       scanning?: false,
       progress: nil,
       current_root_id: "root",
       pending_action: nil,
       acted: %{},
       undo_offer: nil,
       last_action_target: nil,
       last_scanned_at: DateTime.utc_now()
     )
     |> assign_derived()
     # A fresh scan re-roots, so drop any ?node= from the URL
     |> push_patch(to: ~p"/")}
  end

  def handle_info({:scan_error, :not_authenticated}, socket) do
    {:noreply,
     socket
     |> assign(scanning?: false, progress: nil, auth_status: TokenStore.status())
     |> put_flash(:error, "Gmail is not connected. Please connect and try again.")}
  end

  def handle_info({:scan_error, reason}, socket) do
    {:noreply,
     socket
     |> assign(scanning?: false, progress: nil)
     |> put_flash(:error, "Scan failed: #{inspect(reason)}")}
  end

  def handle_info({:action_done, action, count}, socket) do
    # No automatic re-scan: the acted bucket stays visible but grayed out,
    # so the user can see what was done. A manual re-scan refreshes counts.
    acted =
      Map.new(socket.assigns.acted, fn
        {id, %{action: ^action, status: :pending}} -> {id, %{action: action, status: :done}}
        entry -> entry
      end)

    undo_offer =
      case socket.assigns.last_action_target do
        %{action: ^action} = target ->
          %{
            action: action,
            count: count,
            label: target.label,
            node_id: target.node_id,
            status: :ready
          }

        _other ->
          socket.assigns.undo_offer
      end

    {:noreply,
     socket
     |> assign(acted: acted, undo_offer: undo_offer)
     |> assign_derived()
     |> put_flash(:info, action_done_message(action, count) <> " Re-scan to refresh the chart.")}
  end

  def handle_info({:undo_done, _action, count}, socket) do
    acted =
      case socket.assigns.undo_offer do
        %{node_id: node_id} -> Map.delete(socket.assigns.acted, node_id)
        nil -> socket.assigns.acted
      end

    {:noreply,
     socket
     |> assign(acted: acted, undo_offer: nil, last_action_target: nil)
     |> assign_derived()
     |> put_flash(:info, "Undo complete: restored #{count_text(count)} messages.")}
  end

  def handle_info({:undo_error, _action, reason}, socket) do
    undo_offer =
      case socket.assigns.undo_offer do
        %{} = offer -> %{offer | status: :ready}
        nil -> nil
      end

    {:noreply,
     socket
     |> assign(undo_offer: undo_offer)
     |> put_flash(:error, "Undo failed: #{inspect(reason)}")}
  end

  def handle_info({:action_error, action, reason}, socket) do
    # Drop the pending mark so the user can retry the action.
    acted =
      socket.assigns.acted
      |> Enum.reject(fn {_id, entry} -> entry.action == action and entry.status == :pending end)
      |> Map.new()

    {:noreply,
     socket
     |> assign(acted: acted)
     |> assign_derived()
     |> put_flash(:error, "#{action_label(action)} failed: #{inspect(reason)}")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Derived assigns

  defp load_last_result(socket) do
    case Scanner.last_result() do
      {:ok, %{tree: tree, opts: opts, scanned_at: scanned_at} = last} ->
        params = %{
          "group_by" => Atom.to_string(opts.group_by),
          "scope" => Atom.to_string(opts.scope),
          "inbox" => to_string(Map.get(opts, :inbox, false)),
          "window" => Atom.to_string(opts.window),
          "max" => to_string(Map.get(opts, :max) || default_scan_max())
        }

        assign(socket,
          tree: tree,
          last_scanned_at: scanned_at,
          last_scan_max: Map.get(opts, :max),
          user_email: Map.get(last, :email),
          form: to_form(params, as: "scan")
        )

      :empty ->
        socket
    end
  end

  defp assign_derived(%{assigns: %{tree: nil}} = socket) do
    assign(socket, segments: [], crumbs: [], focused: nil, focused_acted: nil)
  end

  defp assign_derived(socket) do
    %{tree: tree, current_root_id: current, acted: acted} = socket.assigns
    focused = Aggregate.find_node(tree, current) || tree

    assign(socket,
      segments: Sunburst.segments(tree, current),
      crumbs: Aggregate.path_to(tree, focused.id) || [tree],
      focused: focused,
      focused_acted: acted_entry(acted, focused.id)
    )
  end

  # Returns the acted entry covering `node_id`: an action applied to a node
  # also covers all of its descendants (their messages match the query too).
  defp acted_entry(acted, node_id) do
    Enum.find_value(acted, fn {id, entry} ->
      if node_id == id or String.starts_with?(node_id, id <> "/"), do: entry
    end)
  end

  defp scan_opts(params) do
    %{
      group_by: parse_option(params["group_by"], domain: :domain, sender: :sender, label: :label),
      scope: parse_option(params["scope"], unread: :unread, all: :all),
      inbox: Map.get(params, "inbox", "true") == "true",
      window: parse_option(params["window"], d30: :d30, d90: :d90, y1: :y1, all: :all),
      max: parse_max(params["max"])
    }
  end

  defp default_params do
    Map.put(@default_params, "max", Integer.to_string(default_scan_max()))
  end

  defp default_scan_max, do: Application.get_env(:unread_herring, :scan_max, 10_000)

  # Let an explicit HERRING_SCAN_MAX above the UI ceiling win, so power
  # users are not fought by the form.
  defp scan_input_max, do: max(@scan_hard_limit, default_scan_max())

  defp parse_max(value) do
    case Integer.parse(to_string(value || "")) do
      {n, _rest} when n >= 1 -> min(n, scan_input_max())
      _not_a_positive_int -> default_scan_max()
    end
  end

  defp parse_option(value, allowed) do
    [{_key, default} | _] = allowed
    Enum.find_value(allowed, default, fn {key, atom} -> Atom.to_string(key) == value && atom end)
  end

  defp parse_action("mark_read"), do: :mark_read
  defp parse_action("archive"), do: :archive
  defp parse_action("trash"), do: :trash
  defp parse_action(_other), do: nil

  ## View helpers

  # The ?authuser= parameter targets a specific signed-in account by email;
  # Google resolves it to the right /u/N/ index itself, so links work no
  # matter the sign-in order. /u/0 is the fallback when the email is unknown.
  #
  # The query is encoded leaving only unreserved chars: Gmail's #search/
  # fragment decodes "+" as a space, and "#"/"&" would corrupt the fragment.
  defp gmail_url(query, nil) do
    "https://mail.google.com/mail/u/0/#search/" <>
      URI.encode(query, &URI.char_unreserved?/1)
  end

  defp gmail_url(query, user_email) do
    "https://mail.google.com/mail/?authuser=#{URI.encode_www_form(user_email)}#search/" <>
      URI.encode(query, &URI.char_unreserved?/1)
  end

  defp percent(share) when is_number(share), do: "#{Float.round(share * 100, 1)}%"

  defp share_of(_count, 0), do: percent(0.0)
  defp share_of(count, total), do: percent(count / total)

  defp action_label(:mark_read), do: "Mark read"
  defp action_label(:archive), do: "Archive"
  defp action_label(:trash), do: "Trash"

  defp confirm_title(:mark_read), do: "Mark as read?"
  defp confirm_title(:archive), do: "Archive?"
  defp confirm_title(:trash), do: "Move to trash?"

  defp confirm_button(:mark_read), do: "Mark read"
  defp confirm_button(:archive), do: "Archive"
  defp confirm_button(:trash), do: "Move to trash"

  defp acted_badge(%{status: :pending}), do: "applying..."
  defp acted_badge(%{action: :mark_read}), do: "Marked read"
  defp acted_badge(%{action: :archive}), do: "Archived"
  defp acted_badge(%{action: :trash}), do: "Trashed"

  defp count_text({:at_least, n}), do: "at least #{n}"
  defp count_text(n), do: to_string(n)

  defp undo_offer_text(%{action: action, count: count, label: label}) do
    "#{acted_badge(%{action: action, status: :done})}: #{count_text(count)} messages in \"#{label}\"."
  end

  # The Scanner reports {:at_least, n} when its id listing hit the cap,
  # meaning more matching messages were left untouched.
  defp action_done_message(action, {:at_least, count}) do
    action_done_message(action, "at least #{count}") <>
      " More messages may match; run the action again to continue."
  end

  defp action_done_message(:mark_read, count), do: "Marked #{count} messages as read."
  defp action_done_message(:archive, count), do: "Archived #{count} messages."
  defp action_done_message(:trash, count), do: "Moved #{count} messages to trash."

  defp truncate(label, max) when byte_size(label) <= max, do: label
  defp truncate(label, max), do: String.slice(label, 0, max - 1) <> "…"

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%= if @auth_status == :unauthenticated do %>
        <.connect_hero />
      <% else %>
        <section class="flex flex-wrap items-end gap-4">
          <.form for={@form} id="scan-form" phx-submit="scan" class="flex flex-wrap items-end gap-3">
            <.input
              type="select"
              field={@form[:group_by]}
              label="Group by"
              options={[{"Domain", "domain"}, {"Sender", "sender"}, {"Label", "label"}]}
            />
            <.input
              type="select"
              field={@form[:scope]}
              label="Scope"
              options={[{"Unread", "unread"}, {"All mail", "all"}]}
            />
            <div
              class="fieldset mb-2"
              title="Match what Gmail's Inbox badge counts; untick to include archived and filtered-away mail"
            >
              <label class="label h-10 cursor-pointer gap-2 select-none">
                <input type="hidden" name={@form[:inbox].name} value="false" />
                <input
                  type="checkbox"
                  id={@form[:inbox].id}
                  name={@form[:inbox].name}
                  value="true"
                  checked={Phoenix.HTML.Form.normalize_value("checkbox", @form[:inbox].value)}
                  class="checkbox checkbox-sm"
                /> Inbox only
              </label>
            </div>
            <.input
              type="select"
              field={@form[:window]}
              label="Window"
              options={[
                {"Last 30 days", "d30"},
                {"Last 90 days", "d90"},
                {"Last year", "y1"},
                {"All time", "all"}
              ]}
            />
            <div
              class="w-32"
              title={"How many of the most recent matching messages to scan (up to #{scan_input_max()}). Each message costs one Gmail API request - roughly 50 per second - so bigger caps scan slower."}
            >
              <.input
                type="number"
                field={@form[:max]}
                label="Max messages"
                min="1"
                max={scan_input_max()}
              />
            </div>
            <button type="submit" class="btn btn-primary mb-2" disabled={@scanning?}>
              {if @scanning?, do: "Scanning...", else: "Scan"}
            </button>
            <button
              type="button"
              id="reset-button"
              class="btn btn-ghost mb-2"
              phx-click="reset"
              disabled={@scanning?}
              title="Forget the cached scan and reset the controls to their defaults"
            >
              Reset
            </button>
          </.form>
          <p :if={@last_scanned_at} class="text-sm opacity-60 mb-2 py-2.5">
            Last scan: {Calendar.strftime(@last_scanned_at, "%Y-%m-%d %H:%M UTC")}
          </p>
        </section>

        <section :if={@scanning?} id="scan-progress" class="space-y-1">
          <%= case @progress do %>
            <% {n, total} when total > 0 -> %>
              <progress class="progress progress-primary w-full" value={n} max={total} />
              <p class="text-sm opacity-70">{n} / {total} messages</p>
            <% _ -> %>
              <progress class="progress progress-primary w-full" />
              <p class="text-sm opacity-70">Listing messages...</p>
          <% end %>
        </section>

        <div
          :if={@tree && @last_scan_max && @tree.count >= @last_scan_max}
          id="scan-cap-notice"
          class="alert alert-warning text-sm"
        >
          <span>
            This scan was capped at the {@last_scan_max} most recent messages, so the
            chart may not show everything. Raise "Max messages" in the controls and
            scan again to cover more.
          </span>
        </div>

        <div :if={@undo_offer} id="undo-bar" class="alert text-sm">
          <span>Last action - {undo_offer_text(@undo_offer)}</span>
          <button
            type="button"
            class="btn btn-sm btn-outline"
            phx-click="undo"
            disabled={@undo_offer.status == :undoing}
          >
            {if @undo_offer.status == :undoing, do: "Undoing...", else: "Undo"}
          </button>
        </div>

        <%= cond do %>
          <% @tree == nil -> %>
            <div :if={!@scanning?} class="hero py-16">
              <div class="hero-content text-center">
                <div>
                  <h2 class="text-2xl font-bold">Ready when you are</h2>
                  <p class="py-2 opacity-70">
                    Pick a grouping and hit Scan to see where your mail comes from.
                  </p>
                </div>
              </div>
            </div>
          <% @segments == [] -> %>
            <p class="py-8 text-center opacity-70">Nothing matched this scan.</p>
          <% true -> %>
            <nav id="breadcrumbs" class="breadcrumbs text-sm">
              <ul>
                <li :for={crumb <- @crumbs}>
                  <%= if crumb.id == @current_root_id do %>
                    <span class="font-semibold">{crumb.label}</span>
                  <% else %>
                    <button
                      type="button"
                      class="link link-hover"
                      phx-click="breadcrumb"
                      phx-value-node-id={crumb.id}
                    >
                      {crumb.label}
                    </button>
                  <% end %>
                </li>
              </ul>
            </nav>

            <div class="flex flex-col lg:flex-row gap-8 items-start">
              <figure class="w-full lg:w-3/5">
                <svg id="sunburst" viewBox={Sunburst.view_box()} role="img" class="w-full">
                  <path
                    :for={seg <- @segments}
                    d={seg.path_d}
                    fill={seg.color}
                    fill-rule="evenodd"
                    stroke="var(--color-base-100, white)"
                    stroke-width="2"
                    phx-click="drill"
                    phx-value-node-id={seg.node_id}
                    class={[
                      seg.has_children? && "cursor-pointer hover:opacity-80",
                      acted_entry(@acted, seg.node_id) && "opacity-30 grayscale"
                    ]}
                  >
                    <title>
                      {seg.label} - {seg.count} ({percent(seg.share)}){case acted_entry(
                                                                              @acted,
                                                                              seg.node_id
                                                                            ) do
                        nil -> ""
                        entry -> " - " <> acted_badge(entry)
                      end}
                    </title>
                  </path>
                  <circle
                    id="sunburst-center"
                    cx={elem(Sunburst.center(), 0)}
                    cy={elem(Sunburst.center(), 1)}
                    r={Sunburst.hole_radius() - 4}
                    fill="transparent"
                    style="pointer-events: all;"
                    class={@current_root_id != "root" && "cursor-pointer"}
                    phx-click="up"
                  >
                    <title>
                      {if @current_root_id == "root", do: @focused.label, else: "Go up one level"}
                    </title>
                  </circle>
                  <text
                    x={elem(Sunburst.center(), 0)}
                    y={elem(Sunburst.center(), 1) - 6}
                    text-anchor="middle"
                    class="fill-current font-semibold"
                    style="font-size: 18px; pointer-events: none;"
                  >
                    {truncate(@focused.label, 18)}
                  </text>
                  <text
                    x={elem(Sunburst.center(), 0)}
                    y={elem(Sunburst.center(), 1) + 18}
                    text-anchor="middle"
                    class="fill-current opacity-70"
                    style="font-size: 14px; pointer-events: none;"
                  >
                    {@focused.count} messages
                  </text>
                </svg>
                <figcaption class="text-center text-xs opacity-50 mt-1">
                  Click a wedge to drill down; click the center to go back up.
                  Counts are individual messages, not Gmail conversations, so they
                  can be higher than Gmail's sidebar badge.
                </figcaption>
              </figure>

              <aside id="side-panel" class="w-full lg:w-2/5 space-y-4">
                <div class="card bg-base-200">
                  <div class="card-body p-4 space-y-2">
                    <h3 class="card-title text-base">
                      {@focused.label}
                      <span :if={@focused_acted} class="badge badge-neutral badge-sm">
                        {acted_badge(@focused_acted)}
                      </span>
                    </h3>
                    <p class="text-sm opacity-70">{@focused.count} messages</p>
                    <p :if={is_nil(@focused.query)} class="text-xs opacity-60">
                      These senders could not be parsed, so this bucket cannot be searched
                      or acted on in Gmail.
                    </p>
                    <div :if={@focused.query} class="card-actions items-center gap-2">
                      <a
                        href={gmail_url(@focused.query, @user_email)}
                        target="_blank"
                        rel="noopener"
                        class="btn btn-sm btn-outline"
                      >
                        Open in Gmail
                      </a>
                      <button
                        type="button"
                        class="btn btn-sm"
                        phx-click="request_action"
                        phx-value-action="mark_read"
                        disabled={@focused_acted != nil}
                      >
                        Mark read
                      </button>
                      <button
                        type="button"
                        class="btn btn-sm"
                        phx-click="request_action"
                        phx-value-action="archive"
                        disabled={@focused_acted != nil}
                      >
                        Archive
                      </button>
                      <button
                        type="button"
                        class="btn btn-sm btn-error btn-outline"
                        phx-click="request_action"
                        phx-value-action="trash"
                        disabled={@focused_acted != nil}
                      >
                        Trash
                      </button>
                    </div>
                  </div>
                </div>

                <ol class="space-y-1">
                  <li
                    :for={child <- Enum.take(@focused.children, 30)}
                    class={[
                      "flex items-center gap-2 text-sm rounded px-2 py-1 hover:bg-base-200",
                      acted_entry(@acted, child.id) && "opacity-40"
                    ]}
                  >
                    <span
                      class="inline-block size-3 rounded-full shrink-0"
                      style={"background-color: #{Sunburst.color(child.label, 1)};"}
                    />
                    <%= if child.children != [] do %>
                      <button
                        type="button"
                        class="link link-hover truncate"
                        phx-click="drill"
                        phx-value-node-id={child.id}
                      >
                        {child.label}
                      </button>
                    <% else %>
                      <span class="truncate">{child.label}</span>
                    <% end %>
                    <span
                      :if={acted_entry(@acted, child.id)}
                      class="badge badge-ghost badge-sm shrink-0"
                    >
                      {acted_badge(acted_entry(@acted, child.id))}
                    </span>
                    <span class="ml-auto tabular-nums opacity-70">{child.count}</span>
                    <span class="tabular-nums opacity-50 w-14 text-right">
                      {share_of(child.count, @focused.count)}
                    </span>
                    <a
                      :if={child.query}
                      href={gmail_url(child.query, @user_email)}
                      target="_blank"
                      rel="noopener"
                      class="link text-xs opacity-60"
                    >
                      Gmail
                    </a>
                  </li>
                </ol>
              </aside>
            </div>
        <% end %>

        <div
          :if={@pending_action}
          id="action-confirm-modal"
          class="modal modal-open"
          role="dialog"
        >
          <div class="modal-box">
            <%= if @pending_action[:stage] == :final do %>
              <h3 class="font-bold text-lg text-error">Final confirmation</h3>
              <p class="py-3">
                You are about to
                <strong>{String.downcase(confirm_button(@pending_action.action))}</strong>
                the <strong>entire scan result</strong>
                - "{@pending_action.label}", {@pending_action.count} messages matched in the last scan, plus anything
                else currently matching the same search. Are you absolutely sure?
              </p>
              <div class="modal-action">
                <button type="button" class="btn" phx-click="cancel_action">Cancel</button>
                <button type="button" class="btn btn-error" phx-click="confirm_action">
                  Confirm
                </button>
              </div>
            <% else %>
              <h3 class="font-bold text-lg">{confirm_title(@pending_action.action)}</h3>
              <p :if={@pending_action.query == ""} class="py-2 font-semibold text-error">
                This bucket matches every message in the scan scope - effectively your whole
                mailbox.
              </p>
              <p class="py-3">
                This will affect the messages in "{@pending_action.label}" - {@pending_action.count} matched in the last scan, and the action applies to
                everything currently matching
                <code :if={@pending_action.query != ""} class="text-xs">
                  {@pending_action.query}
                </code>
                <span :if={@pending_action.query == ""}>the scan scope</span>
                (up to 10,000 at a time). Are you sure?
              </p>
              <p :if={@pending_action.action == :trash} class="pb-3 text-sm opacity-70">
                Trashed messages stay recoverable in Gmail for 30 days. Nothing is ever
                permanently deleted by this app.
              </p>
              <div class="modal-action">
                <button type="button" class="btn" phx-click="cancel_action">Cancel</button>
                <button
                  type="button"
                  class={[
                    "btn",
                    if(@pending_action.action == :trash, do: "btn-error", else: "btn-primary")
                  ]}
                  phx-click="confirm_action"
                >
                  {confirm_button(@pending_action.action)}
                </button>
              </div>
            <% end %>
          </div>
        </div>

        <div
          :if={@confirming_logout?}
          id="logout-confirm-modal"
          class="modal modal-open"
          role="dialog"
        >
          <div class="modal-box">
            <h3 class="font-bold text-lg">Disconnect Gmail?</h3>
            <p class="py-3">
              This revokes the app's authorization with Google and deletes the stored
              OAuth token and the local scan cache from this machine. Next time you want
              to use Unread Herring you will have to authorize it with Google again (the
              browser consent flow).
            </p>
            <div class="modal-action">
              <button type="button" class="btn" phx-click="cancel_logout">Cancel</button>
              <button type="button" class="btn btn-warning" phx-click="confirm_logout">
                Disconnect
              </button>
            </div>
          </div>
        </div>

        <footer class="mt-16 border-t border-base-300 pt-4 flex items-center justify-between text-sm opacity-70">
          <a
            href="https://github.com/artkay/unreadherring"
            target="_blank"
            rel="noopener"
            class="link link-hover"
          >
            unread herring
          </a>
          <button
            type="button"
            id="logout-button"
            class="btn btn-ghost btn-sm"
            phx-click="request_logout"
            title="Delete the stored OAuth token and local scan cache"
          >
            Disconnect Gmail
          </button>
        </footer>
      <% end %>
    </Layouts.app>
    """
  end

  defp connect_hero(assigns) do
    ~H"""
    <div class="hero py-24">
      <div class="hero-content text-center">
        <div class="max-w-md space-y-4">
          <h1 class="text-4xl font-bold">Unread Herring</h1>
          <p class="italic opacity-70">"Cut down the mightiest inbox."</p>
          <p class="text-sm opacity-70">
            Connect your Gmail with your own Google OAuth client - this app ships no
            credentials, stores everything locally, and only ever talks to the Gmail API.
            See the README for the one-time setup.
          </p>
          <a href="/auth" class="btn btn-primary">Connect Gmail</a>
        </div>
      </div>
    </div>
    """
  end
end
