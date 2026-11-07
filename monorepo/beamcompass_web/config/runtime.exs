import Config

if path = System.get_env("BEAMCOMPASS_NAVIGATOR_SNAPSHOT") do
  config :beamcompass_web, :navigator_snapshot_path, path
end

if catalog = System.get_env("BEAMCOMPASS_NAVIGATOR_CATALOG") do
  config :beamcompass_web, :navigator_catalog_dir, catalog
end

if System.get_env("BEAMCOMPASS_WEB_SERVE") == "1" do
  secret = System.fetch_env!("BEAMCOMPASS_SECRET_KEY_BASE")

  if byte_size(secret) < 64 do
    raise "BEAMCOMPASS_SECRET_KEY_BASE must be at least 64 bytes"
  end

  port = String.to_integer(System.get_env("BEAMCOMPASS_WEB_PORT", "4115"))

  config :beamcompass_web, BeamCompassWeb.Endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: port],
    secret_key_base: secret
end
