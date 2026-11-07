defmodule BeamCompassCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamcompass_core,
      version: "0.1.0",
      elixir: ">= 1.20.5",
      name: "BeamCompass Core",
      description:
        "Source-grounded behavioral architecture analysis for Elixir/OTP applications.",
      source_url: "https://github.com/nshkrdotcom/beamcompass",
      homepage_url: "https://github.com/nshkrdotcom/beamcompass",
      package: package(),
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/beamcompass"},
      files: [
        "lib",
        "mix.exs",
        ".formatter.exs",
        "README.md",
        "LICENSE",
        "assets/*"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/beamcompass_core.svg",
      assets: %{"assets" => "assets"},
      source_ref: "main",
      source_url_pattern:
        "https://github.com/nshkrdotcom/beamcompass/blob/main/monorepo/beamcompass_core/%{path}#L%{line}",
      extras: [
        {"README.md", [title: "Overview"]},
        {"LICENSE", [title: "License"]}
      ],
      groups_for_extras: [
        {"Getting started", ["README.md"]},
        {"Project", ["LICENSE"]}
      ],
      groups_for_modules: [
        {"Public API", [BeamCompass]},
        {"Analysis", ~r/^BeamCompass.Analysis/},
        {"Source inspection", ~r/^BeamCompass.Source/},
        {"Data model", ~r/^BeamCompass.Model/},
        {"Utilities", [BeamCompass.Json, BeamCompass.Id]},
        {"Mix tasks", ~r/^Mix.Tasks/}
      ]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
