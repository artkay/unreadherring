# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :unread_herring,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :unread_herring, UnreadHerringWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: UnreadHerringWeb.ErrorHTML, json: UnreadHerringWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: UnreadHerring.PubSub,
  live_view: [signing_salt: "URGZrEvq"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Where the token + last-scan cache live. Overridden per environment;
# resolved at runtime by UnreadHerring.Config.
config :unread_herring, :config_dir, {:home, ".config/unread_herring"}

# Default cap on messages fetched per scan (each message costs one Gmail
# metadata request). Override at runtime with HERRING_SCAN_MAX.
config :unread_herring, :scan_max, 10_000

# Gmail OAuth scope ceiling: modify only (no permanent delete).
config :unread_herring, UnreadHerring.Auth,
  client_id: nil,
  client_secret: nil,
  scope: "https://www.googleapis.com/auth/gmail.modify"

# NODE_PATH must be a single binary (newer esbuild/tailwind hex packages
# reject list env values), so join the entries with the OS path separator.
node_path_separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

node_path =
  Enum.join([Path.expand("../deps", __DIR__), Mix.Project.build_path()], node_path_separator)

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  unread_herring: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => node_path}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  unread_herring: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => node_path}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
