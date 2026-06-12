defmodule UnreadHerringWeb.Router do
  use UnreadHerringWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UnreadHerringWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", UnreadHerringWeb do
    pipe_through :browser

    live "/", DashboardLive
    get "/auth", OAuthController, :request
    get "/oauth/callback", OAuthController, :callback
  end

  # Other scopes may use custom stacks.
  # scope "/api", UnreadHerringWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:unread_herring, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: UnreadHerringWeb.Telemetry
    end
  end
end
