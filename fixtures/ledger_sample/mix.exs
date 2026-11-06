defmodule LedgerSample.MixProject do
  use Mix.Project

  def project, do: [app: :ledger_sample, version: "0.1.0", elixir: "~> 1.18"]
  def application, do: [extra_applications: [:logger]]
end
