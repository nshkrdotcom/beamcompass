defmodule Mix.Tasks.Beamcompass.Navigator do
  @moduledoc """
  Independent, core-only headless consumer of a **saved, validated v2** snapshot.

      mix beamcompass.navigator SNAPSHOT.json [--query 'snapshot=...&lens=...'] [--out VIEW.json]

  Never runs a scanned target Mix project, macro, module or compiler.
  The JSON output is byte-comparable with the Phoenix server's core view.
  """
  use Mix.Task

  alias BeamCompass.Analysis.Navigator
  alias BeamCompass.Behavior.Validator
  alias BeamCompass.Json

  @requirements ["app.config"]
  @shortdoc "Select a pinned source view as standalone typed JSON"

  @impl Mix.Task
  def run(args) do
    {options, inputs, invalid} =
      OptionParser.parse(args, strict: [query: :string, out: :string])

    case {inputs, invalid} do
      {[input], []} ->
        with {:ok, bytes} <- File.read(input),
             {:ok, snapshot} <- JSON.decode(bytes),
             :ok <- Validator.validate(snapshot),
             {:ok, result} <- Navigator.from_query(snapshot, Keyword.get(options, :query, "")) do
          write(result, Keyword.get(options, :out))
        else
          error -> Mix.raise("navigator refused input: #{inspect(error)}")
        end

      _ ->
        Mix.raise("usage: mix beamcompass.navigator SNAPSHOT.json [--query QUERY] [--out FILE]")
    end
  end

  defp write(result, nil), do: IO.puts(Json.encode(result))

  defp write(result, output) do
    case BeamCompass.Behavior.Store.write_json(result, output) do
      :ok -> Mix.shell().info("Saved #{output}")
      {:error, reason} -> Mix.raise("navigator export refused: #{inspect(reason)}")
    end
  end
end
