import Config

# Unread Herring is a single-user, local-first app. Runtime configuration
# comes from environment variables (and the BYO OAuth credentials file,
# resolved later by UnreadHerring.Auth).

# Start the HTTP server when running inside a release (`PHX_SERVER=1`).
if System.get_env("PHX_SERVER") do
  config :unread_herring, UnreadHerringWeb.Endpoint, server: true
end

# Test keeps its own fixed port (4002); don't let the PORT default
# clobber it through the config deep-merge.
if config_env() != :test do
  config :unread_herring, UnreadHerringWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end

# Cap on messages fetched per scan (default 10,000; one Gmail metadata
# request per message, so bigger caps mean longer scans).
if scan_max = System.get_env("HERRING_SCAN_MAX") do
  config :unread_herring, :scan_max, String.to_integer(scan_max)
end

# Bring-your-own OAuth client (Google Cloud "Desktop app" client).
# Either set these env vars or drop a credentials.json into the config dir
# (~/.config/unread_herring/) - see the README.
if client_id = System.get_env("GOOGLE_CLIENT_ID") do
  config :unread_herring, UnreadHerring.Auth,
    client_id: client_id,
    client_secret: System.get_env("GOOGLE_CLIENT_SECRET")
end

if config_env() == :prod do
  config :unread_herring, UnreadHerringWeb.Endpoint,
    url: [host: "localhost", port: String.to_integer(System.get_env("PORT", "4000"))],
    http: [
      # Loopback only: this app must never listen on a public interface.
      ip: {127, 0, 0, 1}
    ],
    # Cookies only need to survive a single local session, so a random
    # per-boot secret is fine (and means no setup step for users).
    secret_key_base:
      System.get_env("SECRET_KEY_BASE") ||
        Base.encode64(:crypto.strong_rand_bytes(48))
end
