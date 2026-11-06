defmodule BeamCompassWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamcompass_web,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:beamcompass_core, path: "../beamcompass_core"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
