defmodule UnreadHerring.AuthTest do
  # async: false because some tests mutate global application env
  use ExUnit.Case, async: false

  alias UnreadHerring.Auth

  @stub UnreadHerring.AuthTest.Stub
  @redirect_uri "http://127.0.0.1:4000/oauth/callback"

  defp req_options, do: [req_options: [plug: {Req.Test, @stub}]]

  defp stub_token_response(response_body) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:token_request, URI.decode_query(body)})
      Req.Test.json(conn, response_body)
    end)
  end

  describe "client_config/0" do
    test "reads from application env" do
      assert {:ok, config} = Auth.client_config()
      assert config.client_id == "test-client-id.apps.googleusercontent.com"
      assert config.client_secret == "test-client-secret"
      assert config.scope == "https://www.googleapis.com/auth/gmail.modify"
    end

    test "falls back to credentials.json when no client_id is configured" do
      original = Application.get_env(:unread_herring, UnreadHerring.Auth)
      Application.put_env(:unread_herring, UnreadHerring.Auth, [])
      on_exit(fn -> Application.put_env(:unread_herring, UnreadHerring.Auth, original) end)

      path = UnreadHerring.Config.path("credentials.json")

      File.write!(
        path,
        Jason.encode!(%{installed: %{client_id: "file-id", client_secret: "file-secret"}})
      )

      on_exit(fn -> File.rm(path) end)

      assert {:ok, config} = Auth.client_config()
      assert config.client_id == "file-id"
      assert config.client_secret == "file-secret"
      assert config.scope == "https://www.googleapis.com/auth/gmail.modify"
    end

    test "returns an error when nothing is configured" do
      original = Application.get_env(:unread_herring, UnreadHerring.Auth)
      Application.put_env(:unread_herring, UnreadHerring.Auth, [])
      on_exit(fn -> Application.put_env(:unread_herring, UnreadHerring.Auth, original) end)

      File.rm(UnreadHerring.Config.path("credentials.json"))

      assert {:error, :missing_credentials} = Auth.client_config()
    end
  end

  describe "authorize_url/2" do
    test "contains all required params" do
      url = Auth.authorize_url("the-state", @redirect_uri)
      uri = URI.parse(url)

      assert uri.scheme == "https"
      assert uri.host == "accounts.google.com"
      assert uri.path == "/o/oauth2/v2/auth"

      assert URI.decode_query(uri.query) == %{
               "response_type" => "code",
               "client_id" => "test-client-id.apps.googleusercontent.com",
               "redirect_uri" => @redirect_uri,
               "scope" => "https://www.googleapis.com/auth/gmail.modify",
               "state" => "the-state",
               "access_type" => "offline",
               "prompt" => "consent"
             }
    end
  end

  describe "exchange_code/3" do
    test "posts the authorization-code form and builds a token map" do
      stub_token_response(%{
        "access_token" => "new-access-token",
        "refresh_token" => "new-refresh-token",
        "expires_in" => 3600,
        "scope" => "https://www.googleapis.com/auth/gmail.modify",
        "token_type" => "Bearer"
      })

      assert {:ok, token} = Auth.exchange_code("the-code", @redirect_uri, req_options())

      assert_received {:token_request, params}

      assert params == %{
               "grant_type" => "authorization_code",
               "code" => "the-code",
               "client_id" => "test-client-id.apps.googleusercontent.com",
               "client_secret" => "test-client-secret",
               "redirect_uri" => @redirect_uri
             }

      assert token.access_token == "new-access-token"
      assert token.refresh_token == "new-refresh-token"
      assert token.scope == "https://www.googleapis.com/auth/gmail.modify"
      assert token.token_type == "Bearer"
      assert_in_delta token.expires_at, System.system_time(:second) + 3600, 5
    end

    test "returns an error tuple on a non-200 response" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error":"invalid_grant"}))
      end)

      assert {:error, {:http_error, 400, %{"error" => "invalid_grant"}}} =
               Auth.exchange_code("bad-code", @redirect_uri, req_options())
    end
  end

  describe "refresh/2" do
    test "posts the refresh-token form and keeps the old refresh token" do
      stub_token_response(%{
        "access_token" => "refreshed-access-token",
        "expires_in" => 3599,
        "scope" => "https://www.googleapis.com/auth/gmail.modify",
        "token_type" => "Bearer"
      })

      assert {:ok, token} = Auth.refresh("old-refresh-token", req_options())

      assert_received {:token_request, params}

      assert params == %{
               "grant_type" => "refresh_token",
               "refresh_token" => "old-refresh-token",
               "client_id" => "test-client-id.apps.googleusercontent.com",
               "client_secret" => "test-client-secret"
             }

      assert token.access_token == "refreshed-access-token"
      assert token.refresh_token == "old-refresh-token"
      assert_in_delta token.expires_at, System.system_time(:second) + 3599, 5
    end

    test "uses a new refresh token if Google does return one" do
      stub_token_response(%{
        "access_token" => "refreshed-access-token",
        "refresh_token" => "brand-new-refresh-token",
        "expires_in" => 3600,
        "scope" => "s",
        "token_type" => "Bearer"
      })

      assert {:ok, token} = Auth.refresh("old-refresh-token", req_options())
      assert token.refresh_token == "brand-new-refresh-token"
    end
  end

  describe "revoke/2" do
    test "posts the token to the revoke endpoint" do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:revoke, conn.request_path, URI.decode_query(body)})
        Req.Test.json(conn, %{})
      end)

      assert :ok = Auth.revoke("the-refresh-token", req_options())
      assert_received {:revoke, "/revoke", %{"token" => "the-refresh-token"}}
    end

    test "treats an already-invalid token (400) as success" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_token"})
      end)

      assert :ok = Auth.revoke("stale-token", req_options())
    end

    test "returns an error on other failures" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "unavailable"})
      end)

      assert {:error, {:http_error, 503, _body}} = Auth.revoke("token", req_options())
    end
  end
end
