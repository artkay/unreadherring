defmodule UnreadHerringWeb.DashboardLiveTest do
  # async: false: shares the globally named TokenStore/Scanner and global
  # app env (Req.Test stub in shared mode guards against real HTTP).
  use UnreadHerringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias UnreadHerring.Aggregate
  alias UnreadHerring.Auth.TokenStore

  @moduletag capture_log: true

  setup do
    # The globally named Scanner holds (and persists) the last scan result;
    # earlier tests and earlier suite runs leak through it. Start each test
    # from a clean "never scanned" state.
    File.rm(UnreadHerring.Config.path("last_scan.json"))
    Supervisor.terminate_child(UnreadHerring.Supervisor, UnreadHerring.Scanner)
    {:ok, _pid} = Supervisor.restart_child(UnreadHerring.Supervisor, UnreadHerring.Scanner)

    Req.Test.set_req_test_to_shared()

    Application.put_env(:unread_herring, :scanner_gmail_opts,
      token: "test-token",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    # Auth calls (token refresh, revocation on disconnect) hit the same stub
    Application.put_env(:unread_herring, :auth_req_options,
      plug: {Req.Test, __MODULE__},
      retry: false
    )

    # Default stub: an empty mailbox, so any scan triggered through the
    # global Scanner completes without real HTTP.
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"resultSizeEstimate" => 0})
    end)

    TokenStore.put_token(%{
      access_token: "t",
      refresh_token: "r",
      expires_at: System.system_time(:second) + 3600,
      scope: "https://www.googleapis.com/auth/gmail.modify",
      token_type: "Bearer"
    })

    on_exit(fn ->
      Application.delete_env(:unread_herring, :scanner_gmail_opts)
      Application.delete_env(:unread_herring, :auth_req_options)
      TokenStore.clear()
    end)

    :ok
  end

  defp fixture_tree do
    messages = [
      %{id: "1", from: "Alice <alice@news.com>", label_ids: ["UNREAD"]},
      %{id: "2", from: "Bob <bob@news.com>", label_ids: ["UNREAD"]},
      %{id: "3", from: "Carol <carol@shop.io>", label_ids: ["UNREAD"]}
    ]

    Aggregate.build_tree(messages, %{group_by: :domain, scope: :unread, window: :all})
  end

  test "unauthenticated state shows the Connect Gmail hero", %{conn: conn} do
    TokenStore.clear()

    {:ok, view, html} = live(conn, "/")
    assert html =~ "Connect Gmail"
    assert has_element?(view, ~s|a[href="/auth"]|, "Connect Gmail")
    refute has_element?(view, "#scan-form")
  end

  test "authenticated state shows the scan controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#scan-form")
    assert has_element?(view, ~s|#scan-form select[name="scan[group_by]"]|)
  end

  test "scan progress messages drive the progress bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    send(view.pid, {:scan_started, 10})
    assert render(view) =~ "0 / 10 messages"

    send(view.pid, {:progress, 5, 10})
    html = render(view)
    assert html =~ "5 / 10 messages"
    assert has_element?(view, ~s|#scan-progress progress[value="5"][max="10"]|)
  end

  test "submitting the scan form runs a scan to completion", %{conn: conn} do
    UnreadHerring.Scanner.subscribe()
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:scan_query, URI.decode_query(conn.query_string)["q"]})
      Req.Test.json(conn, %{"resultSizeEstimate" => 0})
    end)

    {:ok, view, _html} = live(conn, "/")

    # Inbox-only is the default
    assert has_element?(view, ~s|#scan-form input[type="checkbox"][name="scan[inbox]"]|)

    view
    |> form("#scan-form", scan: %{group_by: "domain", scope: "unread", window: "d30"})
    |> render_submit()

    assert_receive {:done, _tree}, 2000
    assert_receive {:scan_query, query}
    assert query == "is:unread in:inbox newer_than:30d"
    assert render(view) =~ "Nothing matched this scan."

    # Unticking the checkbox drops the in:inbox restriction
    view
    |> form("#scan-form",
      scan: %{group_by: "domain", scope: "unread", window: "d30", inbox: "false"}
    )
    |> render_submit()

    assert_receive {:done, _tree}, 2000
    assert_receive {:scan_query, "is:unread newer_than:30d"}
  end

  test "done renders the sunburst; drill re-roots; center goes back up", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    send(view.pid, {:done, fixture_tree()})

    html = render(view)
    assert html =~ "news.com"
    assert has_element?(view, ~s|#sunburst path[phx-value-node-id="root/news.com"]|)

    # Drill into the news.com domain wedge
    view
    |> element(~s|#sunburst path[phx-value-node-id="root/news.com"]|)
    |> render_click()

    assert has_element?(view, "#breadcrumbs span.font-semibold", "news.com")

    assert has_element?(
             view,
             ~s|#sunburst path[phx-value-node-id="root/news.com/alice@news.com"]|
           )

    # Center click pops back to the root
    view |> element("#sunburst-center") |> render_click()
    refute has_element?(view, "#breadcrumbs span.font-semibold", "news.com")
    assert has_element?(view, ~s|#sunburst path[phx-value-node-id="root/news.com"]|)
  end

  test "drilling stores the position in the URL and refresh restores it", %{conn: conn} do
    UnreadHerring.Scanner.subscribe()

    # A real (stubbed) scan, so the tree survives a remount via the cache
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.path_info do
        ["gmail", "v1", "users", "me", "profile"] ->
          Req.Test.json(conn, %{"emailAddress" => "me@example.com"})

        ["gmail", "v1", "users", "me", "messages"] ->
          Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}, %{"id" => "m2"}]})

        ["gmail", "v1", "users", "me", "messages", id] ->
          from = %{"m1" => "Alice <alice@news.com>", "m2" => "Carol <carol@shop.io>"}[id]

          Req.Test.json(conn, %{
            "id" => id,
            "labelIds" => ["UNREAD"],
            "payload" => %{"headers" => [%{"name" => "From", "value" => from}]}
          })
      end
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> form("#scan-form") |> render_submit()
    assert_receive {:done, _tree}, 2000

    # Drill patches the URL
    view
    |> element(~s|#sunburst path[phx-value-node-id="root/news.com"]|)
    |> render_click()

    assert_patch(view, "/?node=root%2Fnews.com")
    assert has_element?(view, "#breadcrumbs span.font-semibold", "news.com")

    # "Refresh": a fresh mount of the patched URL lands on the same wedge
    {:ok, view2, _html} = live(conn, "/?node=root/news.com")
    assert has_element?(view2, "#breadcrumbs span.font-semibold", "news.com")

    assert has_element?(
             view2,
             ~s|#sunburst path[phx-value-node-id="root/news.com/alice@news.com"]|
           )

    # Center click goes back up and cleans the URL
    view2 |> element("#sunburst-center") |> render_click()
    assert_patch(view2, "/")

    # A stale or bogus node id falls back to the root without crashing
    {:ok, view3, _html} = live(conn, "/?node=root/nonexistent.example")
    refute has_element?(view3, "#breadcrumbs span.font-semibold", "nonexistent.example")
    assert has_element?(view3, ~s|#sunburst path[phx-value-node-id="root/news.com"]|)
  end

  test "leaf wedges do not re-root", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    send(view.pid, {:done, fixture_tree()})

    view
    |> element(~s|#sunburst path[phx-value-node-id="root/news.com"]|)
    |> render_click()

    # Sender wedges are leaves: clicking one keeps the current root
    view
    |> element(~s|#sunburst path[phx-value-node-id="root/news.com/alice@news.com"]|)
    |> render_click()

    assert has_element?(view, "#breadcrumbs span.font-semibold", "news.com")
  end

  test "side panel has the URI-encoded Open in Gmail anchor", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    send(view.pid, {:done, fixture_tree()})

    html = render(view)

    assert html =~
             "https://mail.google.com/mail/u/0/#search/is%3Aunread%20from%3A%40news.com"

    assert has_element?(view, ~s|#side-panel a[target="_blank"][rel="noopener"]|)
  end

  test "Gmail links target the scanned account when several are logged in", %{conn: conn} do
    UnreadHerring.Scanner.subscribe()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.path_info do
        ["gmail", "v1", "users", "me", "profile"] ->
          Req.Test.json(conn, %{"emailAddress" => "second.account@example.com"})

        ["gmail", "v1", "users", "me", "messages"] ->
          Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}]})

        ["gmail", "v1", "users", "me", "messages", "m1"] ->
          Req.Test.json(conn, %{
            "id" => "m1",
            "labelIds" => ["UNREAD"],
            "payload" => %{
              "headers" => [%{"name" => "From", "value" => "Alice <alice@news.com>"}]
            }
          })
      end
    end)

    {:ok, view, _html} = live(conn, "/")
    view |> form("#scan-form") |> render_submit()
    assert_receive {:done, _tree}, 2000

    html = render(view)
    assert html =~ "https://mail.google.com/mail/?authuser=second.account%40example.com#search/"
    refute html =~ "mail.google.com/mail/u/0/"
  end

  test "mark read is gated by a confirm modal; cancel closes it without acting", %{conn: conn} do
    UnreadHerring.Scanner.subscribe()
    {:ok, view, _html} = live(conn, "/")
    send(view.pid, {:done, fixture_tree()})

    refute has_element?(view, "#action-confirm-modal")

    view |> element(~s|button[phx-value-action="mark_read"]|) |> render_click()
    assert has_element?(view, "#action-confirm-modal")
    assert render(view) =~ "Are you sure?"
    refute_receive {:action_done, _, _}, 150

    view |> element(~s|#action-confirm-modal button[phx-click="cancel_action"]|) |> render_click()
    refute has_element?(view, "#action-confirm-modal")
    refute_receive {:action_done, _, _}, 150
  end

  test "drilled-down (non-root) actions need only one confirmation", %{conn: conn} do
    UnreadHerring.Scanner.subscribe()
    {:ok, view, _html} = live(conn, "/")
    send(view.pid, {:done, fixture_tree()})

    view
    |> element(~s|#sunburst path[phx-value-node-id="root/news.com"]|)
    |> render_click()

    view |> element(~s|button[phx-value-action="mark_read"]|) |> render_click()

    view
    |> element(~s|#action-confirm-modal button[phx-click="confirm_action"]|)
    |> render_click()

    # The stubbed mailbox is empty for the action's id listing, so the
    # action completes having modified zero messages.
    assert_receive {:action_done, :mark_read, 0}, 2000
    assert render(view) =~ "Marked 0 messages as read."
    refute has_element?(view, "#action-confirm-modal")
  end

  test "trash and archive are gone: mark read is the only action", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    send(view.pid, {:done, fixture_tree()})

    assert has_element?(view, ~s|button[phx-value-action="mark_read"]|)
    refute has_element?(view, ~s|button[phx-value-action="trash"]|)
    refute has_element?(view, ~s|button[phx-value-action="archive"]|)

    # Forcing the events does nothing either
    render_click(view, "request_action", %{"action" => "trash"})
    render_click(view, "request_action", %{"action" => "archive"})
    refute has_element?(view, "#action-confirm-modal")
  end

  test "logout is confirmed, then deletes the token and shows the connect hero", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#scan-form")

    # The footer button only opens the confirmation modal
    view |> element("#logout-button") |> render_click()
    assert has_element?(view, "#logout-confirm-modal")
    assert render(view) =~ "authorize it with Google again"
    assert TokenStore.status() == :authenticated

    # Cancel keeps the session
    view |> element(~s|#logout-confirm-modal button[phx-click="cancel_logout"]|) |> render_click()
    refute has_element?(view, "#logout-confirm-modal")
    assert has_element?(view, "#scan-form")
    assert TokenStore.status() == :authenticated

    # Confirming disconnects for real
    view |> element("#logout-button") |> render_click()

    view
    |> element(~s|#logout-confirm-modal button[phx-click="confirm_logout"]|)
    |> render_click()

    html = render(view)
    assert html =~ "Connect Gmail"
    assert html =~ "revoked at Google"
    refute has_element?(view, "#scan-form")
    assert TokenStore.status() == :unauthenticated
    assert UnreadHerring.Scanner.last_result() == :empty
  end

  test "root-level mark read takes a double confirmation and grays the bucket", %{conn: conn} do
    UnreadHerring.Scanner.subscribe()
    {:ok, view, _html} = live(conn, "/")
    send(view.pid, {:done, fixture_tree()})

    # Mark read opens the confirm modal rather than firing immediately
    view |> element(~s|button[phx-value-action="mark_read"]|) |> render_click()
    assert has_element?(view, "#action-confirm-modal")
    assert render(view) =~ "Mark as read?"
    assert render(view) =~ "Are you sure?"
    refute_receive {:action_done, _, _}, 150

    # Root-level action: first confirm advances to the final confirmation
    view
    |> element(~s|#action-confirm-modal button[phx-click="confirm_action"]|)
    |> render_click()

    assert render(view) =~ "Final confirmation"
    refute_receive {:action_done, _, _}, 150

    view
    |> element(~s|#action-confirm-modal button[phx-click="confirm_action"]|)
    |> render_click()

    assert_receive {:action_done, :mark_read, 0}, 2000
    html = render(view)

    # Acted state: badge on the focused card, button disabled, wedges
    # grayed (root was acted on, so all descendant wedges are covered)
    assert html =~ "Marked read"
    assert has_element?(view, ~s|button[phx-value-action="mark_read"][disabled]|)
    assert has_element?(view, ~s|#sunburst path[class*="grayscale"]|)

    # Clicking the action again is a no-op (no new modal)
    render_click(view, "request_action", %{"action" => "mark_read"})
    refute has_element?(view, "#action-confirm-modal")

    # A fresh scan clears the acted state
    send(view.pid, {:done, fixture_tree()})
    refute has_element?(view, ~s|#sunburst path[class*="grayscale"]|)
    refute has_element?(view, ~s|button[phx-value-action="mark_read"][disabled]|)
  end

  test "a dropped-messages scan shows the incomplete warning", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    refute has_element?(view, "#scan-incomplete-notice")
    send(view.pid, {:scan_incomplete, 120, 10_000})

    assert has_element?(view, "#scan-incomplete-notice")
    html = render(view)
    assert html =~ "120 of 10000 messages"
    assert html =~ "quota"
  end

  test "a rescan completing while the modal is open keeps the captured target", %{conn: conn} do
    UnreadHerring.Scanner.subscribe()
    {:ok, view, _html} = live(conn, "/")
    send(view.pid, {:done, fixture_tree()})

    # Drill into news.com, open the confirm modal there
    view
    |> element(~s|#sunburst path[phx-value-node-id="root/news.com"]|)
    |> render_click()

    view |> element(~s|button[phx-value-action="mark_read"]|) |> render_click()
    assert has_element?(view, "#action-confirm-modal")

    # A scan completes mid-confirmation and re-roots the chart: the modal
    # must close rather than silently retarget to the new root.
    send(view.pid, {:done, fixture_tree()})
    refute has_element?(view, "#action-confirm-modal")
    refute_receive {:action_done, _, _}, 150
  end

  test "buckets with unparseable senders have no Gmail link or actions", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    messages = [%{id: "1", from: "garbage-not-an-address", label_ids: ["UNREAD"]}]
    tree = Aggregate.build_tree(messages, %{group_by: :domain, scope: :unread, window: :all})
    send(view.pid, {:done, tree})

    # Drill into the unknown bucket; it cannot be searched in Gmail
    view
    |> element(~s|#sunburst path[phx-value-node-id="root/unknown"]|)
    |> render_click()

    assert render(view) =~ "cannot be searched"
    refute has_element?(view, ~s|button[phx-value-action="mark_read"]|)

    # request_action without a query must be a no-op even if forced
    render_click(view, "request_action", %{"action" => "mark_read"})
    refute has_element?(view, "#action-confirm-modal")
  end

  test "a scan that hits the cap shows the truncation notice", %{conn: conn} do
    original_max = Application.get_env(:unread_herring, :scan_max)
    Application.put_env(:unread_herring, :scan_max, 3)
    on_exit(fn -> Application.put_env(:unread_herring, :scan_max, original_max) end)

    UnreadHerring.Scanner.subscribe()

    mailbox = [
      %{id: "m1", from: "Alice <alice@news.com>"},
      %{id: "m2", from: "Bob <bob@news.com>"},
      %{id: "m3", from: "Carol <carol@shop.io>"}
    ]

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.path_info do
        ["gmail", "v1", "users", "me", "profile"] ->
          Req.Test.json(conn, %{"emailAddress" => "me@example.com"})

        ["gmail", "v1", "users", "me", "messages"] ->
          Req.Test.json(conn, %{"messages" => Enum.map(mailbox, &%{"id" => &1.id})})

        ["gmail", "v1", "users", "me", "messages", id] ->
          message = Enum.find(mailbox, &(&1.id == id))

          Req.Test.json(conn, %{
            "id" => id,
            "labelIds" => ["UNREAD"],
            "payload" => %{"headers" => [%{"name" => "From", "value" => message.from}]}
          })
      end
    end)

    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "#scan-cap-notice")

    view |> form("#scan-form") |> render_submit()
    assert_receive {:done, _tree}, 2000

    assert has_element?(view, "#scan-cap-notice")
    assert render(view) =~ "Max messages"
  end

  test "the max input defaults from config, drives the scan, and is clamped", %{conn: conn} do
    UnreadHerring.Scanner.subscribe()
    {:ok, view, _html} = live(conn, "/")

    # Defaults to the configured :scan_max
    default = Application.get_env(:unread_herring, :scan_max)
    assert has_element?(view, ~s|#scan-form input[name="scan[max]"][value="#{default}"]|)

    # A custom value is passed through to the Scanner
    view |> form("#scan-form", scan: %{max: "250"}) |> render_submit()
    assert_receive {:done, _tree}, 2000
    assert {:ok, %{opts: %{max: 250}}} = UnreadHerring.Scanner.last_result()

    # Values beyond the ceiling are clamped server-side
    view |> form("#scan-form", scan: %{max: "999999999"}) |> render_submit()
    assert_receive {:done, _tree}, 2000
    assert {:ok, %{opts: %{max: 100_000}}} = UnreadHerring.Scanner.last_result()

    # Garbage falls back to the default
    view |> form("#scan-form", scan: %{max: "herring"}) |> render_submit()
    assert_receive {:done, _tree}, 2000
    assert {:ok, %{opts: %{max: ^default}}} = UnreadHerring.Scanner.last_result()
  end

  test "reset clears the chart, the cached scan, and the controls", %{conn: conn} do
    UnreadHerring.Scanner.subscribe()
    {:ok, view, _html} = live(conn, "/")

    # Run a real (stubbed, empty) scan so the Scanner has a cached result,
    # then show a fixture tree and tweak a control.
    view |> form("#scan-form", scan: %{max: "250"}) |> render_submit()
    assert_receive {:done, _tree}, 2000
    assert {:ok, _last} = UnreadHerring.Scanner.last_result()

    send(view.pid, {:done, fixture_tree()})
    assert has_element?(view, "#sunburst")

    view |> element("#reset-button") |> render_click()

    refute has_element?(view, "#sunburst")
    assert render(view) =~ "Ready when you are"
    assert UnreadHerring.Scanner.last_result() == :empty

    default = Application.get_env(:unread_herring, :scan_max)
    assert has_element?(view, ~s|#scan-form input[name="scan[max]"][value="#{default}"]|)
  end

  test "scan_error flash for lost authentication", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    send(view.pid, {:scan_error, :not_authenticated})
    assert render(view) =~ "Gmail is not connected"
  end
end
