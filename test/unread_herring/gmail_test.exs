defmodule UnreadHerring.GmailTest do
  # async: false because fetch_metadata runs requests in supervised tasks,
  # which requires Req.Test stubs in shared mode (global).
  use ExUnit.Case, async: false

  alias UnreadHerring.Gmail

  @moduletag capture_log: true

  @token "test-access-token"

  setup do
    Req.Test.set_req_test_to_shared()
    :ok
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [token: @token, req_options: [plug: {Req.Test, UnreadHerring.Gmail}, retry: false]],
      extra
    )
  end

  describe "list_message_ids/2" do
    test "paginates with q, maxResults, and pageToken params" do
      test_pid = self()

      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        params = URI.decode_query(conn.query_string)
        send(test_pid, {:list_request, conn.request_path, params})

        case params["pageToken"] do
          nil ->
            Req.Test.json(conn, %{
              "messages" => [%{"id" => "m1"}, %{"id" => "m2"}],
              "nextPageToken" => "page-2"
            })

          "page-2" ->
            Req.Test.json(conn, %{"messages" => [%{"id" => "m3"}]})
        end
      end)

      assert {:ok, ["m1", "m2", "m3"]} = Gmail.list_message_ids("is:unread", opts())

      assert_received {:list_request, path, first_params}
      assert path == "/gmail/v1/users/me/messages"
      assert first_params["q"] == "is:unread"
      assert first_params["maxResults"] == "500"
      refute Map.has_key?(first_params, "pageToken")

      assert_received {:list_request, _path, second_params}
      assert second_params["q"] == "is:unread"
      assert second_params["maxResults"] == "500"
      assert second_params["pageToken"] == "page-2"
    end

    test "empty mailbox (response without a messages key) returns {:ok, []}" do
      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        Req.Test.json(conn, %{"resultSizeEstimate" => 0})
      end)

      assert {:ok, []} = Gmail.list_message_ids("is:unread", opts())
    end

    test "caps ids at opts[:max], truncating and stopping pagination" do
      test_pid = self()

      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        params = URI.decode_query(conn.query_string)
        page = String.to_integer(params["pageToken"] || "0")
        send(test_pid, {:page_fetched, page})

        Req.Test.json(conn, %{
          "messages" => [%{"id" => "p#{page}-a"}, %{"id" => "p#{page}-b"}],
          "nextPageToken" => "#{page + 1}"
        })
      end)

      on_page = fn count -> send(test_pid, {:on_page, count}) end

      assert {:ok, ids} = Gmail.list_message_ids("is:unread", opts(max: 3, on_page: on_page))
      assert ids == ["p0-a", "p0-b", "p1-a"]

      assert_received {:page_fetched, 0}
      assert_received {:page_fetched, 1}
      refute_received {:page_fetched, _}

      assert_received {:on_page, 2}
      assert_received {:on_page, 3}
      refute_received {:on_page, _}
    end
  end

  describe "fetch_metadata/2" do
    test "returns id, from, and label_ids with case-insensitive From match" do
      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        id = conn.request_path |> String.split("/") |> List.last()
        params = URI.decode_query(conn.query_string)
        assert params["format"] == "metadata"
        assert params["metadataHeaders"] == "From"

        Req.Test.json(conn, %{
          "id" => id,
          "labelIds" => ["INBOX", "UNREAD"],
          "payload" => %{
            "headers" => [
              %{"name" => "Subject", "value" => "Hello"},
              %{"name" => "FROM", "value" => "Alice <alice@example.com>"}
            ]
          }
        })
      end)

      assert {:ok, messages} = Gmail.fetch_metadata(["m1", "m2"], opts())
      assert length(messages) == 2

      assert %{id: "m1", from: "Alice <alice@example.com>", label_ids: ["INBOX", "UNREAD"]} in messages

      assert %{id: "m2", from: "Alice <alice@example.com>", label_ids: ["INBOX", "UNREAD"]} in messages
    end

    test "missing From header yields from: nil and missing labelIds yields []" do
      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        Req.Test.json(conn, %{
          "id" => "m1",
          "payload" => %{"headers" => [%{"name" => "Subject", "value" => "no from here"}]}
        })
      end)

      assert {:ok, [%{id: "m1", from: nil, label_ids: []}]} = Gmail.fetch_metadata(["m1"], opts())
    end

    test "a 500 on one id drops that message but returns the rest" do
      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        id = conn.request_path |> String.split("/") |> List.last()

        if id == "bad" do
          Plug.Conn.send_resp(conn, 500, "boom")
        else
          Req.Test.json(conn, %{
            "id" => id,
            "labelIds" => ["INBOX"],
            "payload" => %{
              "headers" => [%{"name" => "From", "value" => "bob@example.com"}]
            }
          })
        end
      end)

      assert {:ok, messages} = Gmail.fetch_metadata(["good-1", "bad", "good-2"], opts())

      assert messages |> Enum.map(& &1.id) |> Enum.sort() == ["good-1", "good-2"]
    end

    test "on_each is called once per id, including dropped ones" do
      test_pid = self()

      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        id = conn.request_path |> String.split("/") |> List.last()

        if id == "bad" do
          Plug.Conn.send_resp(conn, 500, "boom")
        else
          Req.Test.json(conn, %{"id" => id, "labelIds" => [], "payload" => %{"headers" => []}})
        end
      end)

      on_each = fn _result -> send(test_pid, :on_each) end

      assert {:ok, messages} = Gmail.fetch_metadata(["a", "bad", "c"], opts(on_each: on_each))
      assert length(messages) == 2

      assert_received :on_each
      assert_received :on_each
      assert_received :on_each
      refute_received :on_each
    end
  end

  describe "batch_modify/2" do
    test "posts the expected body shape and chunks 1500 ids into two calls" do
      test_pid = self()

      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:batch_request, conn.request_path, Jason.decode!(raw_body)})
        Plug.Conn.send_resp(conn, 204, "")
      end)

      ids = Enum.map(1..1500, &"id-#{&1}")

      assert :ok =
               Gmail.batch_modify(
                 ids,
                 opts(add_label_ids: ["TRASH"], remove_label_ids: ["UNREAD"])
               )

      assert_received {:batch_request, path1, body1}
      assert path1 == "/gmail/v1/users/me/messages/batchModify"
      assert body1["addLabelIds"] == ["TRASH"]
      assert body1["removeLabelIds"] == ["UNREAD"]
      assert length(body1["ids"]) == 1000

      assert_received {:batch_request, _path2, body2}
      assert body2["addLabelIds"] == ["TRASH"]
      assert body2["removeLabelIds"] == ["UNREAD"]
      assert length(body2["ids"]) == 500

      assert body1["ids"] ++ body2["ids"] == ids
      refute_received {:batch_request, _, _}
    end

    test "label id lists default to [] and an error response halts" do
      test_pid = self()

      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:batch_request, Jason.decode!(raw_body)})
        Plug.Conn.send_resp(conn, 403, ~s({"error": "forbidden"}))
      end)

      ids = Enum.map(1..1500, &"id-#{&1}")

      assert {:error, {:http_error, 403, _body}} = Gmail.batch_modify(ids, opts())

      assert_received {:batch_request, body}
      assert body["addLabelIds"] == []
      assert body["removeLabelIds"] == []
      # the second chunk is never sent after the first error
      refute_received {:batch_request, _}
    end
  end

  describe "list_labels/1" do
    test "decodes labels into id/name/type maps" do
      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        assert conn.request_path == "/gmail/v1/users/me/labels"

        Req.Test.json(conn, %{
          "labels" => [
            %{"id" => "INBOX", "name" => "INBOX", "type" => "system"},
            %{"id" => "Label_7", "name" => "Newsletters", "type" => "user"}
          ]
        })
      end)

      assert {:ok,
              [
                %{id: "INBOX", name: "INBOX", type: "system"},
                %{id: "Label_7", name: "Newsletters", type: "user"}
              ]} = Gmail.list_labels(opts())
    end
  end

  describe "rate limiting" do
    test "a 403 rateLimitExceeded is retried with backoff" do
      # Gmail reports per-user rate limiting as 403 (not 429); the request
      # must back off and retry rather than fail and drop the message.
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
          1 ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{
              "error" => %{
                "code" => 403,
                "errors" => [%{"domain" => "usageLimits", "reason" => "rateLimitExceeded"}],
                "status" => "PERMISSION_DENIED"
              }
            })

          _later ->
            Req.Test.json(conn, %{"messages" => [%{"id" => "m1"}]})
        end
      end)

      retrying_opts = [
        token: @token,
        req_options: [plug: {Req.Test, UnreadHerring.Gmail}, retry_delay: fn _n -> 1 end]
      ]

      assert {:ok, ["m1"]} = Gmail.list_message_ids("is:unread", retrying_opts)
      assert Agent.get(attempts, & &1) == 2
    end

    test "a non-rate-limit 403 is not retried" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        Agent.update(attempts, &(&1 + 1))

        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{
          "error" => %{
            "code" => 403,
            "errors" => [%{"domain" => "global", "reason" => "insufficientPermissions"}],
            "status" => "PERMISSION_DENIED"
          }
        })
      end)

      retrying_opts = [
        token: @token,
        req_options: [plug: {Req.Test, UnreadHerring.Gmail}, retry_delay: fn _n -> 1 end]
      ]

      assert {:error, {:http_error, 403, _body}} =
               Gmail.list_message_ids("is:unread", retrying_opts)

      assert Agent.get(attempts, & &1) == 1
    end
  end

  describe "get_profile/1" do
    test "returns the authenticated account's email address" do
      Req.Test.stub(UnreadHerring.Gmail, fn conn ->
        assert conn.request_path == "/gmail/v1/users/me/profile"
        Req.Test.json(conn, %{"emailAddress" => "me@example.com", "messagesTotal" => 42})
      end)

      assert {:ok, %{email_address: "me@example.com"}} = Gmail.get_profile(opts())
    end
  end
end
