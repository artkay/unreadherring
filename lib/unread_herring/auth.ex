defmodule UnreadHerring.Auth do
  @moduledoc """
  Hand-rolled OAuth 2.0 installed-app loopback flow for Google, built on Req.

  The repo ships no credentials: each user brings their own Google Cloud
  OAuth client (Desktop type, Testing mode). Client credentials are resolved
  from application config first, then from a `credentials.json` file (the
  format Google offers for download for Desktop clients) in the config
  directory.
  """

  @authorize_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @revoke_endpoint "https://oauth2.googleapis.com/revoke"
  @default_scope "https://www.googleapis.com/auth/gmail.modify"

  @doc """
  Resolves the OAuth client configuration.

  Primary source is `Application.get_env(:unread_herring, UnreadHerring.Auth)`
  (`:client_id`, `:client_secret`, optional `:scope`). When no `:client_id`
  is configured, falls back to `credentials.json` in the config directory,
  in Google's downloaded Desktop-client format:

      {"installed": {"client_id": "...", "client_secret": "..."}}

  Returns `{:ok, %{client_id: ..., client_secret: ..., scope: ...}}` or
  `{:error, :missing_credentials}`.
  """
  def client_config do
    env = Application.get_env(:unread_herring, __MODULE__) || []
    scope = Keyword.get(env, :scope, @default_scope)

    case Keyword.get(env, :client_id) do
      nil ->
        credentials_from_file(scope)

      client_id ->
        {:ok,
         %{
           client_id: client_id,
           client_secret: Keyword.get(env, :client_secret),
           scope: scope
         }}
    end
  end

  defp credentials_from_file(scope) do
    with {:ok, body} <- File.read(UnreadHerring.Config.path("credentials.json")),
         {:ok, %{"installed" => %{"client_id" => client_id, "client_secret" => client_secret}}} <-
           Jason.decode(body) do
      {:ok, %{client_id: client_id, client_secret: client_secret, scope: scope}}
    else
      _ -> {:error, :missing_credentials}
    end
  end

  @doc """
  Builds the Google consent URL for the loopback flow.

  Requests offline access (so Google returns a refresh token) and forces the
  consent prompt (so a refresh token is issued even on re-auth).
  """
  def authorize_url(state, redirect_uri) do
    case client_config() do
      {:ok, config} ->
        query =
          URI.encode_query(%{
            "response_type" => "code",
            "client_id" => config.client_id,
            "redirect_uri" => redirect_uri,
            "scope" => config.scope,
            "state" => state,
            "access_type" => "offline",
            "prompt" => "consent"
          })

        @authorize_endpoint <> "?" <> query

      {:error, :missing_credentials} ->
        raise "missing Google OAuth client credentials; see the BYO-credentials setup in the README"
    end
  end

  @doc """
  Exchanges an authorization code for a token map.

  Returns `{:ok, token_map}` with atom keys: `:access_token`,
  `:refresh_token`, `:expires_at` (unix seconds, computed from the
  `expires_in` Google returns), `:scope` and `:token_type`.

  Pass `req_options: [...]` in `opts` (or set the `:auth_req_options` app
  env) to inject Req options such as `plug: {Req.Test, Stub}` in tests.
  """
  def exchange_code(code, redirect_uri, opts \\ []) do
    with {:ok, config} <- client_config() do
      token_request(
        [
          grant_type: "authorization_code",
          code: code,
          client_id: config.client_id,
          client_secret: config.client_secret,
          redirect_uri: redirect_uri
        ],
        opts
      )
    end
  end

  @doc """
  Refreshes an access token using a refresh token.

  Google does not return a new refresh token on refresh, so the returned
  token map keeps the refresh token that was passed in (unless Google does
  return one, which then wins).
  """
  def refresh(refresh_token, opts \\ []) do
    with {:ok, config} <- client_config(),
         {:ok, token} <-
           token_request(
             [
               grant_type: "refresh_token",
               refresh_token: refresh_token,
               client_id: config.client_id,
               client_secret: config.client_secret
             ],
             opts
           ) do
      {:ok, %{token | refresh_token: token.refresh_token || refresh_token}}
    end
  end

  @doc """
  Revokes a token at Google, withdrawing the app's authorization.

  Revoking the refresh token invalidates the entire grant (all associated
  access tokens included), so pass the refresh token when there is one.
  Google answers 200 on success and 400 when the token is already invalid
  or revoked - the latter is treated as success since the end state is the
  same.
  """
  def revoke(token, opts \\ []) do
    request_options =
      [url: @revoke_endpoint, form: [token: token]]
      |> Keyword.merge(Application.get_env(:unread_herring, :auth_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.post(request_options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: 400}} -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp token_request(form, opts) do
    request_options =
      [url: @token_endpoint, form: form]
      |> Keyword.merge(Application.get_env(:unread_herring, :auth_req_options, []))
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.post(request_options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, to_token_map(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_token_map(body) do
    %{
      access_token: body["access_token"],
      refresh_token: body["refresh_token"],
      expires_at: System.system_time(:second) + (body["expires_in"] || 0),
      scope: body["scope"],
      token_type: body["token_type"]
    }
  end
end
