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

    test "broadcasts scan_incomplete when metadata fetches are dropped", %{
      cache_path: cache_path
    } do
      # m2's metadata fetch fails persistently (as under Gmail rate
      # limiting once retries are exhausted) and is dropped from the tree.
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.path_info do
          ["gmail", "v1", "users", "me", "profile"] ->
            Req.Test.json(conn, %{"emailAddress" => "me@example.com"})

          ["gmail", "v1", "users", "me", "messages"] ->
            Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}, %{"id" => "m2"}]})

          ["gmail", "v1", "users", "me", "messages", "m2"] ->
            Plug.Conn.send_resp(conn, 403, "rateLimitExceeded")

          ["gmail", "v1", "users", "me", "messages", id] ->
            Req.Test.json(conn, %{
              "id" => id,
              "labelIds" => ["UNREAD"],
              "payload" => %{"headers" => [%{"name" => "From", "value" => "a@news.com"}]}
            })
        end
      end)

      {name, _pid} = start_scanner!(cache_path, :s1)
      Scanner.scan(name, %{group_by: :domain, scope: :unread, window: :all})

      assert_receive {:scan_incomplete, 1, 2}, 2000
      assert_receive {:done, tree}, 2000
      assert tree.count == 1
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
    test "mark_read removes only the UNREAD label and never deletes", %{
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
        end
      end)

      {name, _pid} = start_scanner!(cache_path, :s1)
      Scanner.apply_action(name, "is:unread from:@news.com", :mark_read)

      assert_receive {:action_done, :mark_read, 2}, 2000
      assert_receive {:batch_body, body}

      assert body["ids"] == ["m1", "m2"]
      assert body["addLabelIds"] == []
      assert body["removeLabelIds"] == ["UNREAD"]

      # The safety ceiling: nothing in the app ever issues a DELETE, and
      # mark-read is the only action that exists.
      refute_received {:request, "DELETE", _path}
    end

    test "only mark_read is an accepted action", %{cache_path: cache_path} do
      {name, _pid} = start_scanner!(cache_path, :s1)

      for forbidden <- [:trash, :archive, :delete] do
        assert_raise FunctionClauseError, fn ->
          Scanner.apply_action(name, "from:@news.com", forbidden)
        end
      end
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
