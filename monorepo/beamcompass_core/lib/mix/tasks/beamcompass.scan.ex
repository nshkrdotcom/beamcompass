defmodule Mix.Tasks.Beamcompass.Scan do
  @moduledoc """
  Scan a checkout without evaluating its code.

      mix beamcompass.scan PATH [--out FILE]
  """
  use Mix.Task

  @shortdoc "Inventory source-grounded behavioral facts"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, paths, invalid} = OptionParser.parse(args, strict: [out: :string])

    case {paths, invalid} do
      {[path], []} ->
        case BeamCompass.scan(path) do
          {:ok, snapshot} ->
            out = Keyword.get(opts, :out, "beamcompass-snapshot.json")
            :ok = BeamCompass.save(snapshot, out)

            Mix.shell().info(
              "Saved #{out} (#{length(snapshot.facts)} facts; #{length(snapshot.issues)} issues)"
            )

          {:error, reason} ->
            Mix.raise("scan failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("usage: mix beamcompass.scan PATH [--out FILE]")
    end
  end
end
