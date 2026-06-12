defmodule UnreadHerringWeb.OAuthController do
  @moduledoc """
  OAuth loopback endpoints: `/auth` redirects to Google's consent screen and
  `/oauth/callback` exchanges the returned code for a token, handing it to
  `UnreadHerring.Auth.TokenStore`.
  """

  use UnreadHerringWeb, :controller

  alias UnreadHerring.Auth
  alias UnreadHerring.Auth.TokenStore

  def request(conn, _params) do
    case Auth.client_config() do
      {:ok, _config} ->
        state = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        redirect_uri = url(~p"/oauth/callback")

        conn
        |> put_session(:oauth_state, state)
        |> redirect(external: Auth.authorize_url(state, redirect_uri))

      {:error, :missing_credentials} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, setup_help())
    end
  end

  def callback(conn, %{"error" => error}) do
    conn
    |> put_flash(:error, "Google authorization failed: #{error}")
    |> redirect(to: ~p"/")
  end

  def callback(conn, %{"state" => state, "code" => code}) do
    expected_state = get_session(conn, :oauth_state)

    if is_binary(expected_state) and Plug.Crypto.secure_compare(expected_state, state) do
      conn = delete_session(conn, :oauth_state)
      redirect_uri = url(~p"/oauth/callback")

      case Auth.exchange_code(code, redirect_uri) do
        {:ok, token} ->
          :ok = TokenStore.put_token(token)

          conn
          |> put_flash(:info, "Connected to Gmail.")
          |> redirect(to: ~p"/")

        {:error, reason} ->
          conn
          |> put_flash(:error, "Token exchange failed: #{inspect(reason)}")
          |> redirect(to: ~p"/")
      end
    else
      send_resp(conn, 403, "Invalid OAuth state")
    end
  end

  def callback(conn, _params) do
    send_resp(conn, 403, "Invalid OAuth callback")
  end

  defp setup_help do
    config_dir = UnreadHerring.Config.dir()

    """
    <!DOCTYPE html>
    <html>
      <head><title>Unread Herring - OAuth setup needed</title></head>
      <body style="font-family: sans-serif; max-width: 42rem; margin: 3rem auto; line-height: 1.6;">
        <h1>Google OAuth client not configured</h1>
        <p>
          Unread Herring ships no credentials - you bring your own Google
          Cloud OAuth client, which stays private to you. This is a one-time
          setup of about five minutes; all links below open the right page
          in the Google Cloud Console.
        </p>
        <ol>
          <li>
            <a href="https://console.cloud.google.com/projectcreate" target="_blank" rel="noopener">
              Create a Google Cloud project</a> (any name, e.g. <code>unread-herring</code>),
            or pick an existing one.
          </li>
          <li>
            <a href="https://console.cloud.google.com/apis/library/gmail.googleapis.com" target="_blank" rel="noopener">
              Enable the Gmail API</a> for that project.
          </li>
          <li>
            <a href="https://console.cloud.google.com/apis/credentials/consent" target="_blank" rel="noopener">
              Configure the OAuth consent screen</a>: choose External, fill in the
            app name and your email, and add <strong>yourself</strong> as a test
            user. Leaving the app in Testing mode is fine.
          </li>
          <li>
            <a href="https://console.cloud.google.com/apis/credentials/oauthclient" target="_blank" rel="noopener">
              Create an OAuth client ID</a> of type <strong>Desktop app</strong>.
          </li>
          <li>Hand the client to Unread Herring, either way:
            <ul>
              <li>set the <code>GOOGLE_CLIENT_ID</code> and
                  <code>GOOGLE_CLIENT_SECRET</code> environment variables, or</li>
              <li>download the client's JSON and save it as
                  <code>#{Plug.HTML.html_escape(config_dir)}/credentials.json</code>.</li>
            </ul>
          </li>
          <li>Restart the app and visit <a href="/auth">/auth</a> again.</li>
        </ol>
        <p>
          More detail: the project README's "Bring your own OAuth client"
          section walks through the same steps, and Google's own guide is at
          <a href="https://developers.google.com/workspace/guides/create-credentials#desktop-app" target="_blank" rel="noopener">
            developers.google.com/workspace/guides/create-credentials</a>.
        </p>
        <p style="opacity: 0.7; font-size: 0.9em;">
          Why this hassle? Because every user is their own Google Cloud "app",
          your mail is only ever between you and Google - this project never
          operates shared credentials or sees your data.
        </p>
      </body>
    </html>
    """
  end
end
