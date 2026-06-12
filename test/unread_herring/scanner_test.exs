defmodule UnreadHerring.ScannerTest do
  # async: false because the scan runs in supervised tasks (Req.Test must be
  # in shared mode) and because :scanner_gmail_opts is global app env.
  use ExUnit.Case, async: false

  alias UnreadHerring.Scanner

  @moduletag capture_log: true

  setup do
    Req.Test.set_req_test_to_shared()

    Application.put_env(:unread_herring, :scanner_gmail_opts,
      token: "test-token",
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    )

    on_exit(fn -> Application.delete_env(:unread_herring, :scanner_gmail_opts) end)

    Phoenix.PubSub.subscribe(UnreadHerring.PubSub, "scan")

    cache_path =
      Path.join(
        System.tmp_dir!(),
        "herring_scan_cache_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(cache_path) end)

    %{cache_path: cache_path}
  end

  defp start_scanner!(cache_path, id) do
    name = :"scanner_#{id}_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Scanner, name: name, cache_path: cache_path}, id: id)
    {name, pid}
  end

  defp stub_mailbox(messages) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.path_info do
        ["gmail", "v1", "users", "me", "profile"] ->
          Req.Test.json(conn, %{"emailAddress" => "me@example.com"})

        ["gmail", "v1", "users", "me", "messages"] ->
          Req.Test.json(conn, %{"messages" => Enum.map(messages, &%{"id" => &1.id})})

        ["gmail", "v1", "users", "me", "messages", id] ->
          message = Enum.find(messages, &(&1.id == id))

          Req.Test.json(conn, %{
            "id" => id,
            "labelIds" => message.label_ids,
            "payload" => %{"headers" => [%{"name" => "From", "value" => message.from}]}
          })
      end
    end)
  end

  @mailbox [
    %{id: "m1", from: "Alice <alice@news.com>", label_ids: ["UNREAD"]},
    %{id: "m2", from: "Bob <bob@news.com>", label_ids: ["UNREAD"]},
    %{id: "m3", from: "Carol <carol@shop.io>", label_ids: ["UNREAD"]}
  ]

  describe "scan/2" do
    test "broadcasts started, progress, and done with the aggregated tree", %{
      cache_path: cache_path
    } do
      stub_mailbox(@mailbox)
      {name, _pid} = start_scanner!(cache_path, :s1)

      Scanner.scan(name, %{group_by: :domain, scope: :unread, window: :all})

      assert_receive {:scan_started, 3}, 2000
      assert_receive {:progress, 3, 3}, 2000
      assert_receive {:done, tree}, 2000

      assert tree.count == 3
      counts = Map.new(tree.children, &{&1.label, &1.count})
      assert counts == %{"news.com" => 2, "shop.io" => 1}

      assert {:ok, %{tree: ^tree, opts: opts, scanned_at: %DateTime{}, email: "me@example.com"}} =
               Scanner.last_result(name)

      assert opts.group_by == :domain
    end

    test "persists the last scan and a new scanner serves it from the cache", %{
      cache_path: cache_path
    } do
      stub_mailbox(@mailbox)
      {name, _pid} = start_scanner!(cache_path, :s1)

      Scanner.scan(name, %{group_by: :domain, scope: :unread, window: :all})
      assert_receive {:done, tree}, 2000
      assert File.exists?(cache_path)

      {name2, _pid} = start_scanner!(cache_path, :s2)

      assert {:ok, %{tree: cached_tree, opts: cached_opts, email: "me@example.com"}} =
               Scanner.last_result(name2)

      assert cached_tree == tree

      assert cached_opts == %{
               group_by: :domain,
               scope: :unread,
               inbox: true,
               window: :all,
               max: Application.get_env(:unread_herring, :scan_max)
             }
    end

    test "a scan requested while one is running is ignored", %{cache_path: cache_path} do
      Req.Test.stub(__MODULE__, fn conn ->
        Process.sleep(150)
        Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}]})
      end)

      {name, _pid} = start_scanner!(cache_path, :s1)
      Scanner.scan(name, %{})
      Scanner.scan(name, %{})

      assert_receive {:scan_started, _}, 2000
      assert_receive {:done, _tree}, 2000
      refute_receive {:scan_started, _}, 300
      refute_receive {:done, _}, 100
    end

    test "broadcasts scan_error when not authenticated", %{cache_path: cache_path} do
      # No token in the injected opts and the global TokenStore is empty,
      # so the Gmail layer reports :not_authenticated before any request.
      Application.put_env(:unread_herring, :scanner_gmail_opts,
        req_options: [plug: {Req.Test, __MODULE__}, retry: false]
      )

      UnreadHerring.Auth.TokenStore.clear()

      {name, _pid} = start_scanner!(cache_path, :s1)
      Scanner.scan(name, %{})

      assert_receive {:scan_error, :not_authenticated}, 2000
    end
  end

  describe "apply_action/3" do
    test "trash lists ids for the query and batchModifies with TRASH only", %{
      cache_path: cache_path
    } do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})

        case conn.path_info do
          ["gmail", "v1", "users", "me", "messages"] ->
            assert URI.decode_query(conn.query_string)["q"] == "is:unread from:@news.com"
            Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}, %{"id" => "m2"}]})

          ["gmail", "v1", "users", "me", "messages", "batchModify"] ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:batch_body, Jason.decode!(body)})
            Plug.Conn.send_resp(conn, 204, "")

          ["gmail", "v1", "users", "me", "messages", id] ->
            Req.Test.json(conn, %{"id" => id, "labelIds" => ["UNREAD", "INBOX"]})
        end
      end)

      {name, _pid} = start_scanner!(cache_path, :s1)
      Scanner.apply_action(name, "is:unread from:@news.com", :trash)

      assert_receive {:action_done, :trash, 2}, 2000
      assert_receive {:batch_body, body}

      assert body["ids"] == ["m1", "m2"]
      assert body["addLabelIds"] == ["TRASH"]
      assert body["removeLabelIds"] == []

      # The scope ceiling: nothing in the app ever issues a DELETE.
      refute_received {:request, "DELETE", _path}
    end

    test "mark_read removes the UNREAD label", %{cache_path: cache_path} do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.path_info do
          ["gmail", "v1", "users", "me", "messages"] ->
            Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}]})

          ["gmail", "v1", "users", "me", "messages", "batchModify"] ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:batch_body, Jason.decode!(body)})
            Plug.Conn.send_resp(conn, 204, "")

          ["gmail", "v1", "users", "me", "messages", id] ->
            Req.Test.json(conn, %{"id" => id, "labelIds" => ["UNREAD", "INBOX"]})
        end
      end)

      {name, _pid} = start_scanner!(cache_path, :s1)
      Scanner.apply_action(name, "from:a@b.c", :mark_read)

      assert_receive {:action_done, :mark_read, 1}, 2000
      assert_receive {:batch_body, body}
      assert body["addLabelIds"] == []
      assert body["removeLabelIds"] == ["UNREAD"]
    end
  end

  describe "undo_last_action/1" do
    defp stub_action_mailbox(test_pid, labels_by_id) do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.path_info do
          ["gmail", "v1", "users", "me", "messages"] ->
            Req.Test.json(conn, %{
              "messages" => Enum.map(Map.keys(labels_by_id), &%{"id" => &1})
            })

          ["gmail", "v1", "users", "me", "messages", "batchModify"] ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:batch_body, Jason.decode!(body)})
            Plug.Conn.send_resp(conn, 204, "")

          ["gmail", "v1", "users", "me", "messages", id] ->
            Req.Test.json(conn, %{"id" => id, "labelIds" => Map.fetch!(labels_by_id, id)})
        end
      end)
    end

    test "restores the snapshotted pre-action labels (incl. implicit ones)", %{
      cache_path: cache_path
    } do
      # Trashing also implicitly strips INBOX, so undoing a trash must put
      # INBOX (and the unread state) back, not just remove TRASH.
      stub_action_mailbox(self(), %{"m1" => ["UNREAD", "INBOX"], "m2" => ["UNREAD", "INBOX"]})

      {name, _pid} = start_scanner!(cache_path, :s1)

      Scanner.apply_action(name, "from:@news.com", :trash)
      assert_receive {:action_done, :trash, 2}, 2000
      assert_receive {:batch_body, action_body}
      assert action_body["addLabelIds"] == ["TRASH"]

      Scanner.undo_last_action(name)
      assert_receive {:undo_done, :trash, 2}, 2000
      assert_receive {:batch_body, undo_body}

      assert Enum.sort(undo_body["ids"]) == Enum.sort(action_body["ids"])
      assert undo_body["addLabelIds"] == ["INBOX", "UNREAD"]
      assert undo_body["removeLabelIds"] == ["TRASH"]

      # One-shot: a second undo has nothing left to undo
      Scanner.undo_last_action(name)
      assert_receive {:undo_error, nil, :nothing_to_undo}, 2000
    end

    test "does not mark previously-read messages unread", %{cache_path: cache_path} do
      # m1 was unread, m2 was already read before the mark-read action:
      # undo restores UNREAD only on m1.
      stub_action_mailbox(self(), %{"m1" => ["UNREAD", "INBOX"], "m2" => ["INBOX"]})

      {name, _pid} = start_scanner!(cache_path, :s1)

      Scanner.apply_action(name, "from:@news.com", :mark_read)
      assert_receive {:action_done, :mark_read, 2}, 2000
      assert_receive {:batch_body, _action_body}

      Scanner.undo_last_action(name)
      assert_receive {:undo_done, :mark_read, 2}, 2000

      assert_receive {:batch_body, body_a}
      assert_receive {:batch_body, body_b}
      bodies = Enum.sort_by([body_a, body_b], & &1["ids"])

      assert [
               %{"ids" => ["m1"], "addLabelIds" => ["UNREAD"], "removeLabelIds" => []},
               %{"ids" => ["m2"], "addLabelIds" => [], "removeLabelIds" => ["UNREAD"]}
             ] = bodies
    end

    test "with no prior action reports nothing_to_undo", %{cache_path: cache_path} do
      {name, _pid} = start_scanner!(cache_path, :s1)
      Scanner.undo_last_action(name)
      assert_receive {:undo_error, nil, :nothing_to_undo}, 2000
    end
  end

  describe "last_result/1" do
    test "corrupt cache file means :empty", %{cache_path: cache_path} do
      File.write!(cache_path, "not json {{{")
      {name, _pid} = start_scanner!(cache_path, :s1)
      assert Scanner.last_result(name) == :empty
    end
  end

  describe "clear/1" do
    test "forgets the cached result and deletes the cache file", %{cache_path: cache_path} do
      stub_mailbox(@mailbox)
      {name, _pid} = start_scanner!(cache_path, :s1)

      Scanner.scan(name, %{group_by: :domain, scope: :unread, window: :all})
      assert_receive {:done, _tree}, 2000
      assert File.exists?(cache_path)

      assert :ok = Scanner.clear(name)
      assert Scanner.last_result(name) == :empty
      refute File.exists?(cache_path)

      # A fresh scanner on the same path starts empty too
      {name2, _pid} = start_scanner!(cache_path, :s2)
      assert Scanner.last_result(name2) == :empty
    end
  end
end
