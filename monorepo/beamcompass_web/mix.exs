defmodule BeamCompassWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamcompass_web,
      version: "0.1.0",
      elixir: ">= 1.20.5",
      name: "BeamCompass Web",
      description:
        "Standalone Phoenix LiveView navigator and offline BeamCompass source reports.",
      source_url: "https://github.com/nshkrdotcom/beamcompass",
      homepage_url: "https://github.com/nshkrdotcom/beamcompass",
      package: package(),
      docs: docs(),
      deps: deps(),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {BeamCompassWeb.Application, []}]
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
        "CHANGELOG.md",
        "LICENSE",
        "assets/js/*",
        "assets/ts/*",
        "assets/package.json",
        "assets/package-lock.json",
        "assets/tsconfig.json",
        "priv/static/*",
        "config/*"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/beamcompass_web.svg",
      assets: %{"assets" => "assets"},
      source_ref: "main",
      source_url_pattern:
        "https://github.com/nshkrdotcom/beamcompass/blob/main/monorepo/beamcompass_web/%{path}#L%{line}",
      extras: [
        {"README.md", [title: "Overview"]},
        {"CHANGELOG.md", [title: "Changelog"]},
        {"LICENSE", [title: "License"]}
      ],
      groups_for_extras: [
        {"Getting started", ["README.md"]},
        {"Project", ["CHANGELOG.md", "LICENSE"]}
      ],
      groups_for_modules: [
        {"Reports",
         [BeamCompassWeb.Report, BeamCompassWeb.NavigatorLive, BeamCompassWeb.NavigatorSource]},
        {"Mix tasks", ~r/^Mix.Tasks/}
      ]
    ]
  end

  defp core_dependency do
    if Mix.env() != :prod and File.dir?(Path.expand("../beamcompass_core", __DIR__)) do
      {:beamcompass_core, "~> 0.1.0", path: "../beamcompass_core"}
    else
      {:beamcompass_core, "~> 0.1.0"}
    end
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      core_dependency(),
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_html, "~> 4.2"},
      {:bandit, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
