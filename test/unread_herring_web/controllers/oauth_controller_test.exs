defmodule UnreadHerringWeb.OAuthControllerTest do
  # async: false because some tests mutate global application env and the
  # globally registered TokenStore
  use UnreadHerringWeb.ConnCase, async: false

  alias UnreadHerring.Auth.TokenStore

  @stub UnreadHerringWeb.OAuthControllerTest.Stub

  setup do
    TokenStore.clear()

    on_exit(fn ->
      Application.delete_env(:unread_herring, :auth_req_options)
      TokenStore.clear()
    end)

    :ok
  end

  describe "GET /auth" do
    test "redirects to Google with the state stored in the session", %{conn: conn} do
      conn = get(conn, ~p"/auth")

      location = redirected_to(conn)
      assert location =~ "https://accounts.google.com/o/oauth2/v2/auth?"

      state = get_session(conn, :oauth_state)
      assert is_binary(state)

      params = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert params["state"] == state
      assert params["client_id"] == "test-client-id.apps.googleusercontent.com"
      assert params["response_type"] == "code"
      assert params["access_type"] == "offline"
      assert params["prompt"] == "consent"
      assert params["redirect_uri"] == url(~p"/oauth/callback")
    end

    test "explains the BYO-credentials setup when no client is configured", %{conn: conn} do
      original = Application.get_env(:unread_herring, UnreadHerring.Auth)
      Application.put_env(:unread_herring, UnreadHerring.Auth, [])
      on_exit(fn -> Application.put_env(:unread_herring, UnreadHerring.Auth, original) end)
      File.rm(UnreadHerring.Config.path("credentials.json"))

      conn = get(conn, ~p"/auth")

      body = response(conn, 200)
      assert body =~ "GOOGLE_CLIENT_ID"
      assert body =~ "credentials.json"

      # The page must link straight to the console pages and Google's guide
      assert body =~ "https://console.cloud.google.com/projectcreate"
      assert body =~ "https://console.cloud.google.com/apis/library/gmail.googleapis.com"
      assert body =~ "https://console.cloud.google.com/apis/credentials/consent"
      assert body =~ "https://console.cloud.google.com/apis/credentials/oauthclient"
      assert body =~ "https://developers.google.com/workspace/guides/create-credentials"
    end
  end

  describe "GET /oauth/callback" do
    test "with a mismatched state returns 403", %{conn: conn} do
      conn = get(conn, ~p"/auth")
      conn = get(conn, ~p"/oauth/callback", %{"state" => "not-the-state", "code" => "x"})

      assert response(conn, 403) =~ "Invalid OAuth state"
      assert {:error, :not_authenticated} = TokenStore.get_access_token()
    end

    test "without a state in the session returns 403", %{conn: conn} do
      conn = get(conn, ~p"/oauth/callback", %{"state" => "whatever", "code" => "x"})

      assert response(conn, 403) =~ "Invalid OAuth state"
    end

    test "with an error param redirects home with an error flash", %{conn: conn} do
      conn = get(conn, ~p"/oauth/callback", %{"error" => "access_denied"})

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "access_denied"
    end

    test "happy path exchanges the code and stores the token", %{conn: conn} do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "callback-access-token",
          "refresh_token" => "callback-refresh-token",
          "expires_in" => 3600,
          "scope" => "https://www.googleapis.com/auth/gmail.modify",
          "token_type" => "Bearer"
        })
      end)

      Application.put_env(:unread_herring, :auth_req_options, plug: {Req.Test, @stub})

      conn = get(conn, ~p"/auth")
      state = get_session(conn, :oauth_state)

      conn = get(conn, ~p"/oauth/callback", %{"state" => state, "code" => "the-code"})

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connected to Gmail"
      assert get_session(conn, :oauth_state) == nil

      assert TokenStore.status() == :authenticated
      assert {:ok, "callback-access-token"} = TokenStore.get_access_token()
    end
  end
end
