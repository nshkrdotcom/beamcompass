defmodule BeamCompass.Analysis.Invalidation do
  @moduledoc """
  Source-hash driven dependency invalidation for persistent v2 source graphs.

  The scanner still re-extracts a full fresh snapshot: cross-file AST relations
  and new declarations can affect previously unrelated facts. This module
  invalidates cached **dependent analyses**, not merely paths in a UI filter.
  An analysis explicitly declares exact evidence/entity/relation or analysis
  dependencies and may also declare `snapshot:*` or `path:<relative path>`.
  Unknown dependencies are rejected, never optimistically treated as reusable.
  """

  alias BeamCompass.Behavior.Archive
  alias BeamCompass.Json
  alias BeamCompass.Source.Provenance

  @spec plan(map(), list(map()), list(map()), list(map()), keyword()) ::
          {:ok, map()} | {:error, term()}
  def plan(snapshot, old_inputs, new_inputs, analyses, options \\ []) do
    with {:ok, _bundle} <- Archive.build(snapshot, old_inputs),
         :ok <- check_next_inputs(new_inputs),
         :ok <- check_analyses(snapshot, old_inputs, analyses),
         :ok <- check_options(options) do
      old = Map.new(old_inputs, &{&1["path"], &1["sha256"]})
      next = Map.new(new_inputs, &{&1["path"], &1["sha256"]})
      changed = changed_paths(old, next)
      global = global_change?(snapshot, old, next, options)

      evidence = snapshot["evidence"]
      affected_evidence = dependent_evidence(evidence, changed, global)
      ids = MapSet.new(affected_evidence)

      entities = affected_entities(snapshot["entities"], ids, global)
      relations = affected_relations(snapshot["relations"], ids, MapSet.new(entities), global)
      {entities, relations} = dependent_graph_closure(snapshot, ids, entities, relations, global)

      seed =
        MapSet.new(affected_evidence ++ entities ++ relations ++ Enum.map(changed, &("path:" <> &1)))

      # A same-path byte change invalidates its own transitive dependencies;
      # only true global changes invalidate unrelated snapshot-wide caches.
      seed = if global, do: MapSet.put(seed, "snapshot:*"), else: seed
      invalid = invalidated_analyses(analyses, seed)
      all = Enum.map(analyses, & &1["id"])

      {:ok,
       %{
         "format" => "beamcompass.invalidation-plan",
         "schema_version" => 1,
         "before_snapshot_id" => snapshot["snapshot_id"],
         "before_source_digest" => snapshot["manifest"]["source_digest"],
         "after_source_digest" => Provenance.sha256(Json.encode(new_inputs)),
         "changed_paths" => changed,
         "unchanged_paths" => Map.keys(old) |> Enum.filter(&(old[&1] == next[&1])) |> Enum.sort(),
         "invalidated_evidence_ids" => affected_evidence,
         "invalidated_entity_ids" => entities,
         "invalidated_relation_ids" => relations,
         "invalidated_analysis_ids" => invalid,
         "retained_analysis_ids" => Enum.sort(all -- invalid),
         "full_graph_invalidation" => global,
         "fresh_source_reextraction_required" => true,
         "retained_reuse_status" => "provisional_until_fresh_graph_is_verified",
         "limitations" => [
           "Source-hash changes invalidate possible dependencies, not runtime behavior",
           "Incremental analysis cache reuse does not bypass a fresh cross-file source extraction"
         ]
       }}
    end
  end

  defp changed_paths(old, next) do
    (Map.keys(old) ++ Map.keys(next))
    |> Enum.uniq()
    |> Enum.filter(&(old[&1] != next[&1]))
    |> Enum.sort()
  end

  defp global_change?(snapshot, old, next, options) do
    # Additions and deletions can affect incoming relationships: invalidate
    # the whole derived graph rather than claiming safe locality.
    Enum.any?(Map.keys(next), &(not Map.has_key?(old, &1))) or
      Enum.any?(Map.keys(old), &(not Map.has_key?(next, &1))) or
      Keyword.get(options, :config_digest, snapshot["manifest"]["config_digest"]) !=
        snapshot["manifest"]["config_digest"] or
      Keyword.get(options, :providers, snapshot["manifest"]["providers"]) !=
        snapshot["manifest"]["providers"]
  end

  defp dependent_evidence(evidence, changed, global) do
    if global do
      Enum.map(evidence, & &1["id"])
    else
      seed =
        evidence
        |> Enum.filter(&(&1["anchor"]["path"] in changed))
        |> Enum.map(& &1["id"])
        |> MapSet.new()

      closure(evidence, seed)
      |> MapSet.to_list()
      |> Enum.sort()
    end
  end

  defp closure(evidence, changed) do
    expanded =
      Enum.reduce(evidence, changed, fn item, acc ->
        if Enum.any?(item["input_evidence_ids"], &MapSet.member?(changed, &1)) do
          MapSet.put(acc, item["id"])
        else
          acc
        end
      end)

    if MapSet.equal?(changed, expanded), do: changed, else: closure(evidence, expanded)
  end

  defp affected_entities(entities, changed, global) do
    entities
    |> Enum.filter(&(global or Enum.any?(&1["evidence_ids"], &MapSet.member?(changed, &1))))
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  defp affected_relations(relations, evidence_ids, entity_ids, global) do
    relations
    |> Enum.filter(fn rel ->
      global or Enum.any?(rel["evidence_ids"], &MapSet.member?(evidence_ids, &1)) or
        MapSet.member?(entity_ids, rel["source_id"]) or
        MapSet.member?(entity_ids, rel["target_id"])
    end)
    |> Enum.map(& &1["id"])
    |> Enum.sort()
  end

  # An incident relation can change an otherwise unchanged entity's outgoing or
  # incoming architectural meaning. Close over connected typed graph dependencies
  # before preserving caches that declare exact entity or relation inputs.
  defp dependent_graph_closure(snapshot, evidence, entity_ids, relation_ids, global) do
    indexed_relations = Map.new(snapshot["relations"], &{&1["id"], &1})

    endpoints =
      relation_ids
      |> Enum.flat_map(fn id ->
        relation = indexed_relations[id]
        [relation["source_id"], relation["target_id"]]
      end)
      |> Enum.reject(&is_nil/1)

    entities = Enum.sort(Enum.uniq(entity_ids ++ endpoints))
    relations = affected_relations(snapshot["relations"], evidence, MapSet.new(entities), global)

    if entities == entity_ids and relations == relation_ids do
      {entities, relations}
    else
      dependent_graph_closure(snapshot, evidence, entities, relations, global)
    end
  end

  defp invalidated_analyses(analyses, seed) do
    expanded =
      Enum.reduce(analyses, seed, fn entry, acc ->
        if Enum.any?(entry["depends_on"], &MapSet.member?(acc, &1)) do
          MapSet.put(acc, entry["id"])
        else
          acc
        end
      end)

    if MapSet.equal?(seed, expanded) do
      expanded
      |> MapSet.to_list()
      |> Enum.filter(&String.starts_with?(&1, "analysis:"))
      |> Enum.sort()
    else
      invalidated_analyses(analyses, expanded)
    end
  end

  defp check_next_inputs(inputs) when is_list(inputs) do
    if inputs != [] and Enum.all?(inputs, fn input ->
         is_map(input) and Enum.sort(Map.keys(input)) == ~w(path sha256) and
           is_binary(input["path"]) and input["path"] != "" and
           not String.starts_with?(input["path"], "/") and
           not String.contains?(input["path"], ["\\", ":", <<0>>]) and
           Enum.all?(String.split(input["path"], "/"), &(&1 not in ["", ".", ".."])) and
           is_binary(input["sha256"]) and
           Regex.match?(~r/\A[0-9a-f]{64}\z/, input["sha256"])
       end) and
         (Enum.map(inputs, & &1["path"]) ==
            (Enum.map(inputs, & &1["path"]) |> Enum.uniq() |> Enum.sort())) do
      :ok
    else
      {:error, :invalid_next_inputs}
    end
  end

  defp check_next_inputs(_), do: {:error, :invalid_next_inputs}

  defp check_options(options) do
    if Keyword.keyword?(options) and
         Keyword.keys(options) -- [:config_digest, :providers] == [] and
         (not Keyword.has_key?(options, :config_digest) or
            (is_binary(options[:config_digest]) and
               Regex.match?(~r/\A[0-9a-f]{64}\z/, options[:config_digest]))) and
         (not Keyword.has_key?(options, :providers) or is_list(options[:providers])) do
      :ok
    else
      {:error, :invalid_invalidation_options}
    end
  end

  defp check_analyses(snapshot, inputs, analyses) when is_list(analyses) do
    objects =
      MapSet.new(
        Enum.map(snapshot["entities"] ++ snapshot["relations"] ++ snapshot["evidence"], & &1["id"]) ++
          Enum.map(inputs, &("path:" <> &1["path"])) ++ ["snapshot:*"]
      )

    if Enum.all?(analyses, &is_map/1) do
      ids = Enum.map(analyses, & &1["id"])
      allowed = Enum.reduce(ids, objects, &MapSet.put(&2, &1))

      if Enum.all?(ids, &is_binary/1) and ids == Enum.sort(Enum.uniq(ids)) and
           Enum.all?(analyses, fn item ->
             Enum.sort(Map.keys(item)) == ~w(depends_on id) and
               is_binary(item["id"]) and String.starts_with?(item["id"], "analysis:") and
               is_list(item["depends_on"]) and item["depends_on"] != [] and
               item["depends_on"] == Enum.sort(Enum.uniq(item["depends_on"])) and
               Enum.all?(item["depends_on"], &MapSet.member?(allowed, &1)) and
               item["id"] not in item["depends_on"]
           end) do
        :ok
      else
        {:error, :invalid_analysis_dependencies}
      end
    else
      {:error, :invalid_analysis_dependencies}
    end
  end

  defp check_analyses(_, _, _), do: {:error, :invalid_analysis_dependencies}
end
