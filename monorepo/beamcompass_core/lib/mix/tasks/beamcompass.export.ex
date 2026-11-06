defmodule Mix.Tasks.Beamcompass.Export do
  @moduledoc """
  Export a fresh source-only v2 envelope without invoking target code.

      mix beamcompass.export PATH --schema 2 --project-id NAMESPACE --out FILE [--manifest INPUTS_JSON]

  The optional manifest preserves exact relative input hashes and extractor
  settings for independent reproduction; it is not part of the v2 envelope.
  """
  use Mix.Task

  alias BeamCompass.Behavior.{Export, Store}

  @shortdoc "Export a typed source-backed v2 snapshot"
  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {options, paths, invalid} =
      OptionParser.parse(args,
        strict: [schema: :integer, project_id: :string, out: :string, manifest: :string]
      )

    if length(paths) != 1 or invalid != [] or Keyword.get(options, :schema) != 2 or
         not valid_namespace?(Keyword.get(options, :project_id)) or
         is_nil(Keyword.get(options, :out)) do
      Mix.raise(
        "usage: mix beamcompass.export PATH --schema 2 --project-id NAMESPACE --out FILE [--manifest INPUTS_JSON]"
      )
    end

    [path] = paths
    namespace = Keyword.fetch!(options, :project_id)
    output = Keyword.fetch!(options, :out)

    # Export.scan returns both the envelope and the input hashes from ONE read.
    write_from_scan(path, namespace, output, Keyword.get(options, :manifest))
  end

  defp write_from_scan(path, namespace, output, manifest_path) do
    with {:ok, %{snapshot: snapshot} = result} <- Export.scan(path, namespace),
         :ok <- Store.write(snapshot, output),
         :ok <- write_manifest(result, manifest_path) do
      Mix.shell().info(
        "Saved #{output} (#{length(snapshot["entities"])} entities, " <>
          "#{length(snapshot["relations"])} relations, #{length(snapshot["issues"])} issues)"
      )
    else
      {:error, reason} -> Mix.raise("export failed: #{inspect(reason)}")
    end
  end

  defp valid_namespace?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_namespace?(_), do: false

  defp write_manifest(_, nil), do: :ok

  defp write_manifest(result, path) do
    Store.write_json(
      %{
        "source_digest" => result.snapshot["manifest"]["source_digest"],
        "config_digest" => result.snapshot["manifest"]["config_digest"],
        "inputs" => result.inputs,
        "settings" => result.settings
      },
      path
    )
  end
end
