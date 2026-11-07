defmodule BeamCompassWeb.Endpoint do
  @moduledoc "Loopback-first Phoenix/LiveView endpoint consuming only validated source artifacts."
  use Phoenix.Endpoint, otp_app: :beamcompass_web

  @session_options [store: :cookie, key: "_beamcompass_session", signing_salt: "bc-p05-navigator"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/assets",
    from: :beamcompass_web,
    gzip: false,
    only: ~w(app.js stage.js navigator.css)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.Parsers, parsers: [:urlencoded, :multipart], pass: ["*/*"])
  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(BeamCompassWeb.Router)
end
