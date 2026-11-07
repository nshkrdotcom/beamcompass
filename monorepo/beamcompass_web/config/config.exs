import Config

# Not a production secret: the default endpoint does NOT listen on a socket.
# When serving locally, runtime.exs mandates a user-supplied high-entropy secret.
config :beamcompass_web, BeamCompassWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "127.0.0.1"],
  http: [ip: {127, 0, 0, 1}, port: 4115],
  secret_key_base: String.duplicate("0", 64),
  server: false,
  pubsub_server: BeamCompassWeb.PubSub,
  live_view: [signing_salt: "P05nav0005"]

config :phoenix, :json_library, JSON
