defmodule Mix.Tasks.Beamcompass.Inventory do
  @moduledoc "Print inventory counts for a source checkout. Usage: mix beamcompass.inventory PATH"
  use Mix.Task

  @shortdoc "Print a source-grounded architectural inventory"
  @requirements ["app.config"]

  @impl Mix.Task
  def run([path]) do
    case BeamCompass.scan(path) do
      {:ok, snapshot} ->
        snapshot
        |> BeamCompass.inventory()
        |> Enum.sort()
        |> Enum.each(fn {kind, count} -> Mix.shell().info("#{kind}: #{count}") end)

      {:error, reason} ->
        Mix.raise("inventory failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix beamcompass.inventory PATH")
end
