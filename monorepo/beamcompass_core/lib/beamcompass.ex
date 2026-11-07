defmodule BeamCompass do
  @moduledoc """
  Read-only, evidence-backed source inventory of Elixir/OTP repositories.

  No target application code, mix.exs, supervisor or compiler is executed.
  """

  alias BeamCompass.Analysis.ChangeSet
  alias BeamCompass.Analysis.Invalidation
  alias BeamCompass.Analysis.Navigator

  alias BeamCompass.Analysis.{
    Capsules,
    CausalCapsules,
    Diff,
    Projector,
    QuestionAudit,
    SourceProjection
  }

  alias BeamCompass.Artifact.Migration
  alias BeamCompass.Release.Policy
  alias BeamCompass.Behavior.{Archive, Export, Validator}
  alias BeamCompass.Behavior.Store, as: SourceStore
  alias BeamCompass.Id
  alias BeamCompass.Model.{Snapshot, Store}
  alias BeamCompass.Source.{Discovery, Safety, Scanner}

  @spec scan(String.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def scan(path) do
    with {:ok, projects} <- Discovery.discover(path),
         :ok <- Safety.inventory(projects) do
      results =
        for project <- projects, {absolute, relative} <- project.paths do
          scan_file(absolute, relative)
        end

      facts =
        results |> Enum.flat_map(&elem(&1, 0)) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.id)

      issues = results |> Enum.flat_map(&elem(&1, 1)) |> Enum.sort_by(& &1["path"])
      files = results |> Enum.map(&elem(&1, 2)) |> Enum.sort()
      project_records = Enum.map(projects, &Map.take(&1, [:name, :path]))
      id = Id.for_parts(["snapshot-v1", inspect(project_records), inspect(files)])

      {:ok,
       %Snapshot{
         id: id,
         projects: project_records,
         facts: facts,
         capsules: Capsules.build(facts),
         issues: issues
       }}
    end
  end

  defp scan_file(absolute, relative) do
    case Safety.read(absolute, relative, 0) do
      {:ok, source, _total} ->
        scan_source(source, relative)

      {:error, reason} ->
        {[], [%{"path" => relative, "reason" => inspect(reason)}], {relative, "unreadable"}}
    end
  end

  defp scan_source(source, relative) do
    identity = {relative, Id.for_parts([source])}

    case Safety.run(fn -> Scanner.scan(source, relative) end) do
      {:ok, {:ok, facts}} -> {facts, [], identity}
      {:ok, {:error, reason}} -> {[], [%{"path" => relative, "reason" => reason}], identity}
      {:error, reason} -> {[], [%{"path" => relative, "reason" => inspect(reason)}], identity}
    end
  end

  @doc """
  Fresh, source-only typed v2 export. Requires a caller-owned persistent namespace.

  The v1 scan/save/load contracts do not change. This function does **not** take
  a v1 snapshot or synthesize missing provenance from serialized facts.
  Modes other than `:source` and versions other than `2` are refused.
  """
  @spec export_source(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export_source(path, options \\ [])

  def export_source(path, options) when is_binary(path) and is_list(options) do
    if Keyword.keyword?(options) do
      export_with_options(path, options)
    else
      {:error, :invalid_export_options}
    end
  end

  def export_source(%Snapshot{}, _options), do: {:error, :missing_provenance}
  def export_source(_, _), do: {:error, :invalid_source_path}

  defp export_with_options(path, options) do
    namespace = Keyword.get(options, :project_id)
    schema = Keyword.get(options, :schema, 2)
    mode = Keyword.get(options, :mode, :source)

    cond do
      not is_binary(namespace) or String.trim(namespace) == "" ->
        {:error, :project_id_required}

      Keyword.keys(options) -- [:project_id, :schema, :mode] != [] ->
        {:error, :unsupported_export_option}

      schema != 2 ->
        {:error, :unsupported_snapshot_version}

      mode != :source ->
        {:error, :unsupported_evidence_mode}

      true ->
        export_snapshot(path, namespace)
    end
  end

  defp export_snapshot(path, namespace) do
    case Export.scan(path, namespace) do
      {:ok, %{snapshot: snapshot}} -> {:ok, snapshot}
      error -> error
    end
  end

  @doc "Generate a portable exact reference to a v2 entity, relation or evidence record."
  @spec source_reference(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def source_reference(snapshot, kind, id), do: Validator.reference(snapshot, kind, id)

  @doc "Validate an exact v2 reference without joining on labels or semantic keys."
  @spec resolve_source_reference(map(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_source_reference(snapshot, reference),
    do: Validator.validate_reference(snapshot, reference)

  @doc "Atomically persist a validated v2 export. `save/2` remains the v1 writer."
  @spec save_source(map(), String.t()) :: :ok | {:error, term()}
  def save_source(snapshot, path), do: SourceStore.write(snapshot, path)

  @doc "Export a Git-pinned, byte-verified source-only v2 snapshot."
  @spec export_source_git(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def export_source_git(path, project_id) do
    with {:ok, %{snapshot: snapshot}} <- Export.scan_git(path, project_id) do
      {:ok, snapshot}
    end
  end

  @doc "Atomically persist a fresh v2 scan with exact source-input identities."
  @spec archive_source(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def archive_source(source_root, project_id, archive_root) do
    with {:ok, %{snapshot: snapshot, inputs: inputs}} <- Export.scan(source_root, project_id) do
      Archive.put(snapshot, inputs, archive_root)
    end
  end

  @doc "Load a validated immutable v2 bundle by digest and rehydrate its snapshot."
  @spec load_source_archive(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def load_source_archive(archive_root, id), do: Archive.get(archive_root, id)

  @doc "Typed, evidence-backed source-only changes between exact v2 snapshots."
  @spec compare_source(map(), map()) :: {:ok, map()} | {:error, term()}
  def compare_source(before, later_snapshot),
    do: ChangeSet.compare(before, later_snapshot)

  @doc "Plan source-hash and dependent-analysis invalidation without executing target source."
  @spec invalidate_source(map(), list(map()), list(map()), list(map()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def invalidate_source(snapshot, previous_inputs, next_inputs, analyses, options \\ []) do
    Invalidation.plan(
      snapshot,
      previous_inputs,
      next_inputs,
      analyses,
      options
    )
  end

  @doc "Versioned typed preservation request for the source-only v2 export."
  @spec projection_request(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def projection_request(snapshot, options \\ []), do: SourceProjection.request(snapshot, options)

  @doc "Evidence-expandable bounded source-possible capsules, never runtime traces."
  @spec capsules_source(map()) :: {:ok, list(map())} | {:error, term()}
  def capsules_source(snapshot) do
    case Validator.validate(snapshot) do
      :ok -> {:ok, CausalCapsules.build(snapshot)}
      error -> error
    end
  end

  @doc "Project source v2 through a closed request with preservation/omission receipts."
  @spec project_source(map(), map()) :: {:ok, map()} | {:error, term()}
  def project_source(snapshot, request), do: SourceProjection.project(snapshot, request)

  @doc "Answer a typed, source-scoped question using exact v2 relation/evidence refs."
  @spec answer_source(map(), map()) :: {:ok, map()} | {:error, term()}
  def answer_source(snapshot, question), do: QuestionAudit.answer(snapshot, question)

  @doc "Score source-only question answers against an independently authored oracle."
  @spec benchmark_source(map(), list(map())) :: {:ok, map()} | {:error, term()}
  def benchmark_source(snapshot, oracles), do: QuestionAudit.benchmark(snapshot, oracles)

  @doc "Strict source-only navigator view shared by LiveView and standalone consumers."
  @spec navigator_view(map(), map()) :: {:ok, map()} | {:error, term()}
  def navigator_view(source_snapshot_v2, query \\ %{}) do
    Navigator.view(source_snapshot_v2, query)
  end

  @doc "Wrap a validated supported v1/v2 payload without claiming semantic migration."
  @spec wrap_compatibility(Snapshot.t() | map()) :: {:ok, map()} | {:error, term()}
  def wrap_compatibility(snapshot), do: Migration.wrap(snapshot)

  @doc "Rehydrate an exact legacy or v2 payload from a loss-accounted wrapper."
  @spec rehydrate_compatibility(map()) :: {:ok, Snapshot.t() | map()} | {:error, term()}
  def rehydrate_compatibility(envelope), do: Migration.rehydrate(envelope)

  @doc "Fail-closed release eligibility using observed measurements and owner budgets."
  @spec release_eligibility(map(), map() | nil, list(map())) :: {:ok, map()} | {:error, map()}
  def release_eligibility(measured, approval, findings),
    do: Policy.evaluate(measured, approval, findings)

  @spec inventory(Snapshot.t()) :: map()
  def inventory(%Snapshot{} = snapshot) do
    snapshot.facts
    |> Enum.group_by(&Atom.to_string(&1.kind))
    |> Map.new(fn {kind, items} -> {kind, length(items)} end)
  end

  @spec project(Snapshot.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def project(snapshot, options \\ []), do: Projector.project(snapshot, options)

  @spec explain(Snapshot.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def explain(%Snapshot{} = snapshot, fact_id) do
    case Enum.find(snapshot.facts, &(&1.id == fact_id)) do
      nil ->
        {:error, :not_found}

      fact ->
        {:ok,
         %{
           "id" => fact.id,
           "kind" => Atom.to_string(fact.kind),
           "subject" => fact.subject,
           "object" => fact.object,
           "status" => Atom.to_string(fact.status),
           "anchor" => fact.anchor,
           "details" => fact.details
         }}
    end
  end

  @spec diff(Snapshot.t(), Snapshot.t()) :: map()
  def diff(before, later), do: Diff.compare(before, later)

  @spec save(Snapshot.t(), String.t()) :: :ok | {:error, term()}
  def save(snapshot, path), do: Store.write(snapshot, path)

  @spec load(String.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def load(path), do: Store.read(path)
end
