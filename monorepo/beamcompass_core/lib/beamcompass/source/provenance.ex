defmodule BeamCompass.Source.Provenance do
  @moduledoc "Fresh, nonexecuting source bytes/parser context for v2. Never reconstructed from a v1 snapshot."

  alias BeamCompass.Json
  alias BeamCompass.Source.{BoundaryHints, CausalHints, Discovery, Safety}
  alias BeamCompass.Source.Providers.Quoted

  @settings %{
    "adapter" => "beamcompass-elixir-quoted-ast-v1",
    "columns" => true,
    "file_globs" => ["lib/**/*.ex", "lib/**/*.exs"],
    "layouts" => ["immediate-poncho", "monorepo-poncho", "standalone"],
    "mode" => "source",
    "semantic_hints" => "source-boundaries-and-candidate-flow-v2",
    "parser" => "Code.string_to_quoted/2"
  }

  @spec scan(String.t()) :: {:ok, map()} | {:error, term()}
  def scan(path) when is_binary(path) do
    with {:ok, projects} <- Discovery.discover(path),
         :ok <- Safety.inventory(projects),
         {:ok, sources} <- read_sources(projects) do
      parsed_sources = Enum.map(sources, &parse_source/1)
      settings = Map.put(@settings, "resource_guards", Safety.limits())
      fatal = Enum.find(parsed_sources, &Map.has_key?(&1, :fatal_error))

      if fatal do
        {:error, {:source_parser_isolation_failed, fatal.path, fatal.fatal_error}}
      else
        inputs = Enum.map(sources, &%{"path" => &1.path, "sha256" => &1.sha256})

        {:ok,
         %{
           projects: projects,
           sources: parsed_sources,
           inputs: inputs,
           settings: settings,
           source_digest: sha256(Json.encode(inputs)),
           config_digest: sha256(Json.encode(settings)),
           toolchain: %{
             "elixir" => System.version(),
             "otp" => to_string(:erlang.system_info(:otp_release))
           }
         }}
      end
    end
  end

  defp read_sources(projects) do
    projects
    |> Enum.flat_map(fn project ->
      Enum.map(project.paths, fn {absolute, relative} ->
        {absolute, relative, project.path}
      end)
    end)
    |> Enum.sort_by(fn {_absolute, relative, _project} -> relative end)
    |> Enum.reduce_while({:ok, [], 0}, fn {absolute, relative, project}, {:ok, acc, total} ->
      case Safety.read(absolute, relative, total) do
        {:ok, bytes, new_total} ->
          item = %{path: relative, project: project, sha256: sha256(bytes), bytes: bytes}
          {:cont, {:ok, [item | acc], new_total}}

        {:error, reason} ->
          {:halt, {:error, {:source_read_failed, relative, reason}}}
      end
    end)
    |> case do
      {:ok, reversed, _total} -> {:ok, Enum.reverse(reversed)}
      other -> other
    end
  end

  defp parse_source(source) do
    parsed =
      Safety.run(fn ->
        case Quoted.scan(source.bytes, source.path) do
          {:ok, facts} ->
            additions = BoundaryHints.scan(source.bytes, source.path)
            all = (facts ++ additions) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.id)
            %{facts: all, hints: CausalHints.scan(source.bytes), issue: nil}

          {:error, reason} ->
            %{facts: [], hints: [], issue: reason}
        end
      end)

    case parsed do
      {:ok, result} ->
        Map.merge(Map.delete(source, :bytes), result)

      {:error, reason} ->
        Map.merge(Map.delete(source, :bytes), %{
          facts: [],
          hints: [],
          issue: inspect(reason),
          fatal_error: reason
        })
    end
  end

  @spec sha256(binary()) :: String.t()
  def sha256(binary) do
    binary
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
