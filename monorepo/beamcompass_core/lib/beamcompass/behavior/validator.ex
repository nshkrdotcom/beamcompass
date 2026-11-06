defmodule BeamCompass.Behavior.Validator do
  @moduledoc """
  Source-only v2 integrity gate. Rejects closed-mode/version/type violations even
  if a hostile producer recomputes an otherwise consistent snapshot hash.
  """

  alias BeamCompass.Json
  alias BeamCompass.Source.Provenance

  @entity_kinds ~w(
    module function actor trigger state_holder transition effect_intent effect channel
    decision failure_boundary behavior
  )
  @relation_kinds ~w(
    implements handles owns_state calls sends may_deliver_to updates_state
    describes_effect performs_effect supervises may_restart occurs_before
    potentially_concurrent causally_related
  )
  @statuses ~w(sourced derived proposed unresolved)
  @resolutions ~w(resolved possible unresolved)
  @hex64 ~r/\A[0-9a-f]{64}\z/

  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(snapshot) when is_map(snapshot) do
    with :ok <- envelope(snapshot),
         :ok <- manifest(snapshot["manifest"]),
         {:ok, entities} <- indexed(snapshot["entities"], :entities),
         {:ok, relations} <- indexed(snapshot["relations"], :relations),
         {:ok, evidence} <- indexed(snapshot["evidence"], :evidence),
         :ok <- evidence_integrity(evidence, snapshot["manifest"]["providers"]),
         :ok <- entity_integrity(entities, evidence),
         :ok <- relation_integrity(relations, entities, evidence),
         :ok <- issues_integrity(snapshot["issues"], evidence),
         :ok <- insist(sorted_set?(snapshot["limitations"]), :invalid_limitations),
         :ok <- insist(snapshot["snapshot_id"] == fingerprint(snapshot), :snapshot_hash_mismatch) do
      :ok
    end
  end

  def validate(_), do: {:error, :invalid_envelope}

  @spec fingerprint(map()) :: String.t()
  def fingerprint(snapshot) do
    snapshot
    |> Map.delete("snapshot_id")
    |> Json.encode()
    |> Provenance.sha256()
  end

  @spec reference(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reference(snapshot, kind, id) do
    with :ok <- validate(snapshot),
         {:ok, group} <- reference_group(snapshot, kind),
         object when not is_nil(object) <- Enum.find(group, &(&1["id"] == id)) do
      evidences = if(kind == "evidence", do: [id], else: object["evidence_ids"])

      {:ok,
       %{
         "provider" => "beamcompass",
         "snapshot_schema_version" => 2,
         "project_id" => snapshot["project_id"],
         "snapshot_id" => snapshot["snapshot_id"],
         "object_kind" => kind,
         "object_id" => id,
         "evidence_ids" => evidences
       }}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @spec validate_reference(map(), map()) :: {:ok, map()} | {:error, term()}
  def validate_reference(snapshot, reference) when is_map(reference) do
    with :ok <- validate(snapshot),
         :ok <- insist(keys?(reference, reference_keys()), :invalid_reference),
         :ok <- insist(
           reference["provider"] == "beamcompass" and
             reference["snapshot_schema_version"] == 2 and
             reference["project_id"] == snapshot["project_id"] and
             reference["snapshot_id"] == snapshot["snapshot_id"],
           :wrong_reference_namespace
         ),
         {:ok, group} <- reference_group(snapshot, reference["object_kind"]),
         object when not is_nil(object) <- Enum.find(group, &(&1["id"] == reference["object_id"])),
         :ok <- insist(sorted_set?(reference["evidence_ids"]), :invalid_reference_evidence),
         :ok <- insist(reference_evidence?(reference, object), :unrelated_evidence) do
      {:ok, object}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def validate_reference(_, _), do: {:error, :invalid_reference}

  defp reference_keys do
    ~w(provider snapshot_schema_version project_id snapshot_id object_kind object_id evidence_ids)
  end

  defp reference_evidence?(ref, object) do
    allowed =
      if ref["object_kind"] == "evidence", do: [object["id"]], else: object["evidence_ids"]

    ref["evidence_ids"] == allowed
  end

  defp reference_group(snapshot, "entity"), do: {:ok, snapshot["entities"]}
  defp reference_group(snapshot, "relation"), do: {:ok, snapshot["relations"]}
  defp reference_group(snapshot, "evidence"), do: {:ok, snapshot["evidence"]}
  defp reference_group(_, _), do: {:error, :invalid_object_kind}

  defp envelope_keys do
    ~w(format schema_version project_id snapshot_id manifest entities relations evidence issues limitations)
  end

  defp envelope(s) do
    insist(
      keys?(s, envelope_keys()) and
        s["format"] == "beamcompass.snapshot" and s["schema_version"] === 2 and
        text?(s["project_id"]) and hex?(s["snapshot_id"]) and
        Enum.all?(~w(entities relations evidence issues limitations), &is_list(s[&1])),
      :invalid_envelope
    )
  end

  defp manifest(m) when is_map(m) do
    providers = m["providers"]
    toolchain = m["toolchain"]

    with :ok <- insist(
           keys?(m, ~w(source_revision source_digest config_digest toolchain providers)) and
           (is_nil(m["source_revision"]) or text?(m["source_revision"])) and
           hex?(m["source_digest"]) and hex?(m["config_digest"]) and
           is_map(toolchain) and keys?(toolchain, ~w(elixir otp)) and
           text?(toolchain["elixir"]) and text?(toolchain["otp"]),
           :invalid_manifest
         ),
         {:ok, _} <- indexed(providers, :providers),
         :ok <- insist(providers != [] and Enum.all?(providers, &provider?/1), :invalid_provider) do
      :ok
    end
  end

  defp manifest(_), do: {:error, :invalid_manifest}

  defp provider?(p) do
    keys?(p, ~w(id name version mode trust_context)) and
      Enum.all?(~w(id name version trust_context), &text?(p[&1])) and
      p["mode"] == "source"
  end

  defp indexed(items, name) when is_list(items) do
    if Enum.all?(items, &(is_map(&1) and text?(&1["id"]))) and
         Enum.map(items, & &1["id"]) == (Enum.map(items, & &1["id"]) |> Enum.uniq() |> Enum.sort()) do
      {:ok, Map.new(items, &{&1["id"], &1})}
    else
      {:error, {:invalid_collection, name}}
    end
  end

  defp indexed(_, name), do: {:error, {:invalid_collection, name}}

  defp evidence_integrity(evidence, providers) do
    provider_ids = MapSet.new(Enum.map(providers, & &1["id"]))

    with :ok <- insist(Enum.all?(evidence, fn {_id, ev} ->
           keys?(ev, ~w(id provider_id mode anchor basis input_evidence_ids)) and
             MapSet.member?(provider_ids, ev["provider_id"]) and
             ev["mode"] == "source" and text?(ev["basis"]) and
             anchor?(ev["anchor"]) and sorted_set?(ev["input_evidence_ids"]) and
             Enum.all?(ev["input_evidence_ids"], &Map.has_key?(evidence, &1))
         end), :invalid_evidence),
         :ok <- acyclic(evidence) do
      :ok
    end
  end

  defp acyclic(evidence) do
    Enum.reduce_while(Map.keys(evidence), {:ok, MapSet.new()}, fn id, {:ok, seen} ->
      case visit(id, evidence, seen, MapSet.new()) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        :cycle -> {:halt, {:error, :cyclic_evidence}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp visit(id, evidence, seen, active) do
    cond do
      MapSet.member?(active, id) -> :cycle
      MapSet.member?(seen, id) -> {:ok, seen}
      true ->
        active = MapSet.put(active, id)

        Enum.reduce_while(evidence[id]["input_evidence_ids"], {:ok, seen}, fn parent, {:ok, updated} ->
          case visit(parent, evidence, updated, active) do
            {:ok, next} -> {:cont, {:ok, next}}
            :cycle -> {:halt, :cycle}
          end
        end)
        |> case do
          {:ok, updated} -> {:ok, MapSet.put(updated, id)}
          :cycle -> :cycle
        end
    end
  end

  defp entity_integrity(entities, evidence) do
    insist(Enum.all?(entities, fn {_id, e} ->
      keys?(e, ~w(id kind label semantic_key epistemic_status evidence_ids limitations)) and
        e["kind"] in @entity_kinds and text?(e["label"]) and
        (is_nil(e["semantic_key"]) or text?(e["semantic_key"])) and
        e["epistemic_status"] in @statuses and
        cited?(e["evidence_ids"], evidence, true) and sorted_set?(e["limitations"])
    end), :invalid_entity)
  end

  defp relation_integrity(relations, entities, evidence) do
    insist(Enum.all?(relations, fn {_id, r} ->
      source = entities[r["source_id"]]
      target = entities[r["target_id"]]
      resolution = r["resolution"]
      kind = r["kind"]

      keys?(r, ~w(id kind source_id target_id resolution epistemic_status evidence_ids rationale)) and
        kind in @relation_kinds and not is_nil(source) and
        (is_nil(r["target_id"]) or not is_nil(target)) and
        resolution in @resolutions and r["epistemic_status"] in @statuses and
        text?(r["rationale"]) and cited?(r["evidence_ids"], evidence, true) and
        (resolution != "resolved" or not is_nil(target)) and
        (resolution != "unresolved" or (is_nil(target) and r["epistemic_status"] == "unresolved")) and
        typed_effect?(kind, source, target)
    end), :invalid_relation)
  end

  defp typed_effect?("performs_effect", source, target) do
    source["kind"] in ~w(function actor behavior transition) and
      (is_nil(target) or target["kind"] == "effect")
  end

  defp typed_effect?("describes_effect", source, target) do
    source["kind"] in ~w(function actor behavior transition) and
      (is_nil(target) or target["kind"] == "effect_intent")
  end

  defp typed_effect?(_, _, _), do: true

  defp issues_integrity(issues, evidence) do
    valid? = Enum.all?(issues, fn issue ->
      keys?(issue, ~w(code message evidence_ids)) and text?(issue["code"]) and
        text?(issue["message"]) and cited?(issue["evidence_ids"], evidence, false)
    end)

    insist(valid? and issues == Enum.sort_by(issues, &{&1["code"], &1["message"], &1["evidence_ids"]}), :invalid_issues)
  end

  defp anchor?(a) when is_map(a) do
    start_line = a["start_line"]
    start_column = a["start_column"]
    end_line = a["end_line"]
    end_column = a["end_column"]

    keys?(a, ~w(path source_sha256 start_line start_column end_line end_column)) and
      safe_path?(a["path"]) and hex?(a["source_sha256"]) and
      positive_int?(start_line) and positive_int?(start_column) and
      ((is_nil(end_line) and is_nil(end_column)) or
         (positive_int?(end_line) and positive_int?(end_column) and
            {end_line, end_column} >= {start_line, start_column}))
  end

  defp anchor?(_), do: false

  defp safe_path?(path) when is_binary(path) do
    parts = String.split(path, "/")

    text?(path) and not String.starts_with?(path, "/") and
      not String.contains?(path, ["\\", ":", <<0>>]) and
      Enum.all?(parts, &(&1 not in ["", ".", ".."] and &1 != ""))
  end

  defp safe_path?(_), do: false

  defp cited?(refs, evidence, required?) do
    sorted_set?(refs) and (not required? or refs != []) and
      Enum.all?(refs, &Map.has_key?(evidence, &1))
  end

  defp sorted_set?(list) when is_list(list) do
    Enum.all?(list, &text?/1) and list == (list |> Enum.uniq() |> Enum.sort())
  end

  defp sorted_set?(_), do: false

  defp keys?(map, fields) when is_map(map), do: Enum.sort(Map.keys(map)) == Enum.sort(fields)
  defp keys?(_, _), do: false
  defp hex?(value) when is_binary(value), do: Regex.match?(@hex64, value)
  defp hex?(_), do: false
  defp text?(value) when is_binary(value), do: byte_size(value) > 0
  defp text?(_), do: false
  defp positive_int?(value), do: is_integer(value) and value > 0
  defp insist(true, _), do: :ok
  defp insist(false, reason), do: {:error, reason}
end
