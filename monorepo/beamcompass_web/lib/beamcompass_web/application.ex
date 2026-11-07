defmodule BeamCompassWeb.Application do
  @moduledoc "Starts only the trusted BeamCompass web endpoint; no inspected target code is loaded."
  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: BeamCompassWeb.PubSub},
      BeamCompassWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BeamCompassWeb.Supervisor)
  end
end
