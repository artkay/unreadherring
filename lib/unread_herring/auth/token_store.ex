defmodule UnreadHerring.Auth.TokenStore do
  @moduledoc """
  GenServer holding the current OAuth token.

  - `start_link(opts)` - `:name` (default `__MODULE__`) and `:path` (default
    `UnreadHerring.Config.path("token.json")`, resolved lazily in `init/1`);
    loads any persisted token from the path on init. A corrupt or missing
    file simply means unauthenticated.
  - `get_access_token(server \\\\ __MODULE__)` ->
    `{:ok, access_token}` | `{:error, :not_authenticated}` | `{:error, term}`.
    Refreshes lazily (with the refresh token) when the token expires within
    60 seconds; a refresh failure returns
    `{:error, {:refresh_failed, reason}}` while keeping the refresh token so
    a later retry is possible.
  - `put_token(server \\\\ __MODULE__, token)` - store a freshly exchanged
    token map `%{access_token, refresh_token, expires_at, scope, token_type}`
    and persist it with `0600` permissions.
  - `status(server \\\\ __MODULE__)` -> `:authenticated` | `:unauthenticated`
  - `clear(server \\\\ __MODULE__)` - forget + delete the persisted token.
  """

  use GenServer

  require Logger

  @refresh_margin_seconds 60
  @token_keys [:access_token, :refresh_token, :expires_at, :scope, :token_type]

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  # A lazy refresh does a synchronous HTTP round trip to Google (Req's
  # receive timeout is 15s), so give callers more headroom than the
  # default 5s GenServer timeout.
  @call_timeout 30_000

  def get_access_token(server \\ __MODULE__) do
    GenServer.call(server, :get_access_token, @call_timeout)
  end

  def put_token(token), do: put_token(__MODULE__, token)

  def put_token(server, token) do
    GenServer.call(server, {:put_token, token})
  end

  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  @doc """
  Disconnects: revokes the grant at Google (best effort), then forgets and
  deletes the persisted token. Returns `:revoked` when Google confirmed the
  revocation, or `:cleared` when only the local copy could be removed
  (offline, revoke failed, or there was no token) - the caller can tell the
  user to revoke manually in that case.
  """
  def disconnect(server \\ __MODULE__) do
    GenServer.call(server, :disconnect, @call_timeout)
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    default_path? = not Keyword.has_key?(opts, :path)

    path =
      Keyword.get_lazy(opts, :path, fn -> UnreadHerring.Config.path("token.json") end)

    {:ok, %{path: path, default_path?: default_path?, token: load_token(path)}}
  end

  @impl true
  def handle_call(:get_access_token, _from, %{token: nil} = state) do
    {:reply, {:error, :not_authenticated}, state}
  end

  def handle_call(:get_access_token, _from, %{token: token} = state) do
    if expires_soon?(token) do
      case refresh(token) do
        {:ok, refreshed} ->
          persist!(state, refreshed)
          {:reply, {:ok, refreshed.access_token}, %{state | token: refreshed}}

        {:error, reason} ->
          # Keep the token (and its refresh token) so a retry is possible.
          {:reply, {:error, {:refresh_failed, reason}}, state}
      end
    else
      {:reply, {:ok, token.access_token}, state}
    end
  end

  def handle_call({:put_token, token}, _from, state) do
    token = normalize(token)
    persist!(state, token)
    {:reply, :ok, %{state | token: token}}
  end

  def handle_call(:status, _from, state) do
    {:reply, if(state.token, do: :authenticated, else: :unauthenticated), state}
  end

  def handle_call(:clear, _from, state) do
    File.rm(state.path)
    {:reply, :ok, %{state | token: nil}}
  end

  def handle_call(:disconnect, _from, state) do
    result = revoke_grant(state.token)

    # The local copy goes away regardless of whether Google was reachable.
    File.rm(state.path)
    {:reply, result, %{state | token: nil}}
  end

  defp revoke_grant(nil), do: :cleared

  # Revoking the refresh token withdraws the whole grant; fall back to
  # the access token if there is no refresh token.
  defp revoke_grant(token) do
    case UnreadHerring.Auth.revoke(token.refresh_token || token.access_token) do
      :ok ->
        :revoked

      {:error, reason} ->
        Logger.warning("Token revocation at Google failed: #{inspect(reason)}")
        :cleared
    end
  end

  ## Helpers

  defp expires_soon?(%{expires_at: expires_at}) when is_integer(expires_at) do
    expires_at - System.system_time(:second) < @refresh_margin_seconds
  end

  defp expires_soon?(_token), do: true

  defp refresh(%{refresh_token: nil}), do: {:error, :no_refresh_token}
  defp refresh(%{refresh_token: refresh_token}), do: UnreadHerring.Auth.refresh(refresh_token, [])

  defp persist!(%{path: path, default_path?: true}, token) do
    UnreadHerring.Config.write_private!(Path.basename(path), Jason.encode!(token))
  end

  defp persist!(%{path: path}, token) do
    # Lock the file down before the secret is written to it.
    File.touch!(path)
    File.chmod!(path, 0o600)
    File.write!(path, Jason.encode!(token))
  end

  defp load_token(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      normalize(decoded)
    else
      _ -> nil
    end
  end

  defp normalize(token) when is_map(token) do
    Map.new(@token_keys, fn key ->
      {key, Map.get(token, key) || Map.get(token, Atom.to_string(key))}
    end)
  end
end
