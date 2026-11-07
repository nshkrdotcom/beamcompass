defmodule BeamCompassWeb.Router do
  @moduledoc "Routes for the source navigator."
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BeamCompassWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    pipe_through(:browser)
    live("/navigator", BeamCompassWeb.NavigatorLive, :index)
  end
end
