defmodule BeamCompass do
  @moduledoc """
  Read-only, evidence-backed source inventory of Elixir/OTP repositories.

  No target application code, mix.exs, supervisor or compiler is executed.
  """

  alias BeamCompass.Analysis.{Capsules, Diff, Projector}
  alias BeamCompass.Id
  alias BeamCompass.Model.{Snapshot, Store}
  alias BeamCompass.Source.{Discovery, Scanner}

  @spec scan(String.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def scan(path) do
    with {:ok, projects} <- Discovery.discover(path) do
      results =
        for project <- projects, {absolute, relative} <- project.paths do
          case File.read(absolute) do
            {:ok, source} ->
              case Scanner.scan(source, relative) do
                {:ok, facts} -> {facts, [], {relative, Id.for_parts([source])}}
                {:error, reason} -> {[], [%{"path" => relative, "reason" => reason}], {relative, Id.for_parts([source])}}
              end

            {:error, reason} ->
              {[], [%{"path" => relative, "reason" => inspect(reason)}], {relative, "unreadable"}}
          end
        end

      facts = results |> Enum.flat_map(&elem(&1, 0)) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.id)
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
      nil -> {:error, :not_found}
      fact -> {:ok, %{"id" => fact.id, "kind" => Atom.to_string(fact.kind), "subject" => fact.subject, "object" => fact.object, "status" => Atom.to_string(fact.status), "anchor" => fact.anchor, "details" => fact.details}}
    end
  end

  @spec diff(Snapshot.t(), Snapshot.t()) :: map()
  def diff(before, after), do: Diff.compare(before, after)

  @spec save(Snapshot.t(), String.t()) :: :ok | {:error, term()}
  def save(snapshot, path), do: Store.write(snapshot, path)

  @spec load(String.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def load(path), do: Store.read(path)
end
