defmodule Mix.Tasks.Herring.Serve do
  @shortdoc "Starts Unread Herring and opens the dashboard in your browser"

  @moduledoc """
  Boots the app with the HTTP server enabled and opens your default
  browser at the dashboard (or straight into the OAuth flow when no
  Gmail token is stored yet).

      $ mix herring.serve

  The endpoint listens on 127.0.0.1 only.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    Application.put_env(:phoenix, :serve_endpoints, true, persistent: true)
    Mix.Task.run("app.start")

    base = UnreadHerringWeb.Endpoint.url()

    url =
      case UnreadHerring.Auth.TokenStore.status() do
        :authenticated -> base
        :unauthenticated -> base <> "/auth"
      end

    Mix.shell().info("Unread Herring running at #{base} (Ctrl+C twice to quit)")
    UnreadHerring.Browser.open(url)

    unless iex_running?() do
      Process.sleep(:infinity)
    end
  end

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end
end
