defmodule UnreadHerring.Auth.TokenStoreTest do
  # async: false because the refresh tests mutate global application env
  use ExUnit.Case, async: false

  import Bitwise

  alias UnreadHerring.Auth.TokenStore

  @stub UnreadHerring.Auth.TokenStoreTest.Stub

  setup do
    suffix = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "unread_herring_token_#{suffix}.json")
    name = :"token_store_test_#{suffix}"
    on_exit(fn -> File.rm(path) end)
    %{path: path, name: name}
  end

  defp start_store!(name, path) do
    start_supervised!(Supervisor.child_spec({TokenStore, name: name, path: path}, id: name))
  end

  defp valid_token(overrides \\ %{}) do
    Map.merge(
      %{
        access_token: "the-access-token",
        refresh_token: "the-refresh-token",
        expires_at: System.system_time(:second) + 3600,
        scope: "https://www.googleapis.com/auth/gmail.modify",
        token_type: "Bearer"
      },
      overrides
    )
  end

  defp stub_refresh(store_pid, plug_fun) do
    Req.Test.stub(@stub, plug_fun)
    Req.Test.allow(@stub, self(), store_pid)
    Application.put_env(:unread_herring, :auth_req_options, plug: {Req.Test, @stub})
    on_exit(fn -> Application.delete_env(:unread_herring, :auth_req_options) end)
  end

  test "get_access_token before any token is stored", %{name: name, path: path} do
    start_store!(name, path)

    assert TokenStore.status(name) == :unauthenticated
    assert {:error, :not_authenticated} = TokenStore.get_access_token(name)
  end

  test "put_token then get_access_token returns the token", %{name: name, path: path} do
    start_store!(name, path)

    assert :ok = TokenStore.put_token(name, valid_token())
    assert {:ok, "the-access-token"} = TokenStore.get_access_token(name)
    assert TokenStore.status(name) == :authenticated
  end

  test "token persists across restarts", %{name: name, path: path} do
    start_store!(name, path)
    :ok = TokenStore.put_token(name, valid_token())
    :ok = stop_supervised(name)

    restarted = :"#{name}_restarted"
    start_store!(restarted, path)

    assert TokenStore.status(restarted) == :authenticated
    assert {:ok, "the-access-token"} = TokenStore.get_access_token(restarted)
  end

  test "a corrupt token file is treated as unauthenticated", %{name: name, path: path} do
    File.write!(path, "this is not json")
    start_store!(name, path)

    assert TokenStore.status(name) == :unauthenticated
    assert {:error, :not_authenticated} = TokenStore.get_access_token(name)
  end

  test "an expired token is refreshed lazily and persisted", %{name: name, path: path} do
    pid = start_store!(name, path)
    test_pid = self()

    stub_refresh(pid, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:refresh_request, URI.decode_query(body)})

      Req.Test.json(conn, %{
        "access_token" => "refreshed-access-token",
        "expires_in" => 3600,
        "scope" => "https://www.googleapis.com/auth/gmail.modify",
        "token_type" => "Bearer"
      })
    end)

    expired = valid_token(%{expires_at: System.system_time(:second) - 10})
    :ok = TokenStore.put_token(name, expired)

    assert {:ok, "refreshed-access-token"} = TokenStore.get_access_token(name)

    assert_received {:refresh_request, params}
    assert params["grant_type"] == "refresh_token"
    assert params["refresh_token"] == "the-refresh-token"

    persisted = path |> File.read!() |> Jason.decode!()
    assert persisted["access_token"] == "refreshed-access-token"
    assert persisted["refresh_token"] == "the-refresh-token"
  end

  test "a failed refresh returns an error but keeps the refresh token",
       %{name: name, path: path} do
    pid = start_store!(name, path)

    stub_refresh(pid, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"error":"invalid_grant"}))
    end)

    expired = valid_token(%{expires_at: System.system_time(:second) - 10})
    :ok = TokenStore.put_token(name, expired)

    assert {:error, {:refresh_failed, {:http_error, 400, _body}}} =
             TokenStore.get_access_token(name)

    # The refresh token is kept so a retry is possible.
    assert TokenStore.status(name) == :authenticated
    persisted = path |> File.read!() |> Jason.decode!()
    assert persisted["refresh_token"] == "the-refresh-token"
  end

  test "the token file is written with 0600 permissions", %{name: name, path: path} do
    start_store!(name, path)
    :ok = TokenStore.put_token(name, valid_token())

    assert (File.stat!(path).mode &&& 0o777) == 0o600
  end

  test "clear forgets the token and deletes the file", %{name: name, path: path} do
    start_store!(name, path)
    :ok = TokenStore.put_token(name, valid_token())
    assert File.exists?(path)

    assert :ok = TokenStore.clear(name)

    refute File.exists?(path)
    assert TokenStore.status(name) == :unauthenticated
    assert {:error, :not_authenticated} = TokenStore.get_access_token(name)
  end

  describe "disconnect/1" do
    test "revokes the refresh token at Google and clears locally", %{name: name, path: path} do
      pid = start_store!(name, path)
      assert :ok = TokenStore.put_token(name, valid_token())

      test_pid = self()

      stub_refresh(pid, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:revoke_request, conn.request_path, URI.decode_query(body)})
        Req.Test.json(conn, %{})
      end)

      assert TokenStore.disconnect(name) == :revoked
      assert_received {:revoke_request, "/revoke", %{"token" => "the-refresh-token"}}
      refute File.exists?(path)
      assert TokenStore.status(name) == :unauthenticated
    end

    test "clears locally even when revocation fails", %{name: name, path: path} do
      pid = start_store!(name, path)
      assert :ok = TokenStore.put_token(name, valid_token())

      stub_refresh(pid, fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert TokenStore.disconnect(name) == :cleared
      refute File.exists?(path)
      assert TokenStore.status(name) == :unauthenticated
    end

    test "with no token just reports :cleared", %{name: name, path: path} do
      start_store!(name, path)
      assert TokenStore.disconnect(name) == :cleared
    end
  end
end
