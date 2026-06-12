import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :unread_herring, UnreadHerringWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "MHZsiwXIjs9PSCWiAsXw+VDZUaOm+RAths7ciV2f92dun5OkDMWQz5L3hnL7OoJr",
  server: false

# Keep all on-disk state inside the project tmp dir during tests
config :unread_herring, :config_dir, {:path, "tmp/test_config"}

# Dummy OAuth client credentials for tests (never hits Google; Req is stubbed)
config :unread_herring, UnreadHerring.Auth,
  client_id: "test-client-id.apps.googleusercontent.com",
  client_secret: "test-client-secret"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
