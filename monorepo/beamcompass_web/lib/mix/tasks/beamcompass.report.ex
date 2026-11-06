defmodule Mix.Tasks.Beamcompass.Report do
  @moduledoc """
  Write a static self-contained HTML atlas from a source checkout.

      mix beamcompass.report PATH [--out FILE]
  """
  use Mix.Task

  @requirements ["app.config"]
  @shortdoc "Create a self-contained operational HTML report"

  @impl Mix.Task
  def run(args) do
    {options, paths, invalid} = OptionParser.parse(args, strict: [out: :string])

    case {paths, invalid} do
      {[path], []} ->
        case BeamCompass.scan(path) do
          {:ok, snapshot} ->
            filename = Keyword.get(options, :out, "beamcompass-report.html")
            :ok = File.mkdir_p(Path.dirname(filename))
            :ok = File.write(filename, BeamCompassWeb.Report.render(snapshot))
            Mix.shell().info("Saved #{filename}")

          {:error, reason} ->
            Mix.raise("report failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("usage: mix beamcompass.report PATH [--out FILE]")
    end
  end
end
