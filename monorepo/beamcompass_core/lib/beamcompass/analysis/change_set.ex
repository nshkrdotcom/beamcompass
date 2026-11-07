defmodule BeamCompass.Analysis.ChangeSet do
  @moduledoc """
  Typed, evidence-backed v2 source graph differences. An exact snapshot ID is a
  location, not a semantic identity. Cross-snapshot matching requires corroborated
  source path/kind and either the same object ID or a unique syntax/typed-neighbor
  signature. The latter is only POSSIBLE structural continuity. Labels and
  semantic keys alone never constitute proof; rename/split/merge stay uncertain.

  This records *possible source behavior*, not observed execution, proof impact,
  true negative runtime claims, or verified Git chronology.
  """

  alias BeamCompass.Behavior.Validator
  alias BeamCompass.Json
  alias BeamCompass.Source.Provenance

  @focus ~w(transition effect_intent effect failure_boundary decision)
  @relation_types %{
    "describes_effect" => "effect_intent",
    "updates_state" => "transition",
    "may_restart" => "failure_boundary",
    "handles" => "transition",
    "performs_effect" => "effect_site_candidate",
    "causally_related" => "effect_performer_unknown"
  }

  @spec compare(map(), map()) :: {:ok, map()} | {:error, term()}
  def compare(before, later_snapshot) do
    with :ok <- Validator.validate(before),
         :ok <- Validator.validate(later_snapshot),
         true <- before["project_id"] == later_snapshot["project_id"],
         :ok <- validate_revision_consistency(before, later_snapshot) do
      {matches, correspondences} = correspondence(before, later_snapshot)
      entity_changes = entity_changes(before, later_snapshot, matches)
      relation_changes = relation_changes(before, later_snapshot, matches)
      changes = Enum.sort_by(entity_changes ++ relation_changes, & &1["id"])

      body = %{
        "format" => "beamcompass.change-set",
        "schema_version" => 1,
        "before" => lineage(before),
        "after" => lineage(later_snapshot),
        "correspondence" => correspondences,
        "changes" => changes,
        "affected_before_ids" => affected(changes, "before"),
        "affected_after_ids" => affected(changes, "after"),
        "limitations" => [
          "Source-only AST candidates, never observed behavioral causality or negative proof",
          "Matching by unique typed paths/contexts remains possible, not verified runtime continuity",
          "Null source_revision means cross-Git-revision provenance is unavailable",
          "Unchanged exported graph cannot rule out unrepresented changes in source bytes"
        ]
      }

      {:ok, Map.put(body, "change_set_id", fingerprint(body))}
    else
      false -> {:error, :cross_project_correspondence_refused}
      error -> error
    end
  end

  defp validate_revision_consistency(before, later_snapshot) do
    revision = before["manifest"]["source_revision"]

    if is_binary(revision) and revision == later_snapshot["manifest"]["source_revision"] and
         before["manifest"]["source_digest"] != later_snapshot["manifest"]["source_digest"] do
      {:error, :inconsistent_git_source_lineage}
    else
      :ok
    end
  end

  defp fingerprint(value), do: Provenance.sha256(Json.encode(value))
  defp index(items), do: Map.new(items, &{&1["id"], &1})

  defp lineage(snapshot) do
    manifest = snapshot["manifest"]

    %{
      "project_id" => snapshot["project_id"],
      "snapshot_id" => snapshot["snapshot_id"],
      "source_revision" => manifest["source_revision"],
      "source_digest" => manifest["source_digest"],
      "config_digest" => manifest["config_digest"],
      "toolchain" => manifest["toolchain"],
      "providers" => manifest["providers"]
    }
  end

  defp path(object, evidences) do
    objects =
      object["evidence_ids"]
      |> Enum.map(&get_in(evidences, [&1, "anchor", "path"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case objects do
      [only] -> only
      _ -> nil
    end
  end

  defp neighborhood(snapshot) do
    entities = index(snapshot["entities"])

    Enum.reduce(snapshot["relations"], %{}, fn r, acc ->
      from = entities[r["source_id"]]
      to = entities[r["target_id"]]

      out = {"out", r["kind"], r["resolution"], to && to["kind"], to && to["label"]}
      acc = Map.update(acc, from["id"], [out], &[out | &1])

      if to do
        incoming = {"in", r["kind"], r["resolution"], from["kind"], from["label"]}
        Map.update(acc, to["id"], [incoming], &[incoming | &1])
      else
        acc
      end
    end)
    |> Map.new(fn {key, values} -> {key, Enum.sort(values)} end)
  end

  defp structural_key(object, evidences, neighbors) do
    {object["kind"], path(object, evidences), object["label"], object["epistemic_status"],
     Map.get(neighbors, object["id"], [])}
  end

  defp correspondence(before, later_snapshot) do
    old = index(before["entities"])
    later = index(later_snapshot["entities"])
    be = index(before["evidence"])
    ae = index(later_snapshot["evidence"])

    exact =
      old
      |> Map.keys()
      |> Enum.filter(fn id ->
        new = later[id]

        not is_nil(new) and old[id]["kind"] == new["kind"] and
          not is_nil(path(old[id], be)) and path(old[id], be) == path(new, ae)
      end)
      |> Enum.sort()
      |> Map.new(&{&1, &1})

    {matches, _} = extend_structural(exact, old, later, be, ae, before, later_snapshot)
    unresolved_old = Map.keys(old) -- Map.keys(matches)
    unresolved_new = Map.keys(later) -- Map.values(matches)

    known =
      Enum.map(matches, fn {prior, next} ->
        reason =
          if prior == next do
            "exact ID, same kind and corroborating source path"
          else
            "unique syntax, path and typed relation neighborhood; source-only candidate"
          end

        resolution = if prior == next, do: "resolved_source_identity", else: "possible_structural"
        correspondence_row(before, later_snapshot, "matched", resolution, [prior], [next], reason)
      end)

    groups = unmatched_groups(unresolved_old, unresolved_new, old, later, be, ae)

    ambiguous =
      groups
      |> Enum.filter(fn {{_kind, matched_path}, {left, right}} ->
        not is_nil(matched_path) and left != [] and right != []
      end)
      |> Enum.map(fn {_group, {left, right}} ->
        kind = ambiguity_kind(left, right)

        correspondence_row(
          before,
          later_snapshot,
          kind,
          "uncertain",
          left,
          right,
          "same source path and kind only; labels or semantic-key collisions cannot prove continuity"
        )
      end)

    claimed_old = ambiguous |> Enum.flat_map(& &1["before_entity_ids"])
    claimed_new = ambiguous |> Enum.flat_map(& &1["after_entity_ids"])

    unmatched =
      Enum.map(unresolved_old -- claimed_old, fn id ->
        correspondence_row(
          before,
          later_snapshot,
          "unmatched_before",
          "unknown",
          [id],
          [],
          "no evidence-backed uniquely corroborated successor"
        )
      end) ++
        Enum.map(unresolved_new -- claimed_new, fn id ->
          correspondence_row(
            before,
            later_snapshot,
            "unmatched_after",
            "unknown",
            [],
            [id],
            "no evidence-backed uniquely corroborated predecessor"
          )
        end)

    {matches, Enum.sort_by(known ++ ambiguous ++ unmatched, & &1["id"])}
  end

  defp extend_structural(exact, old, later, be, ae, before, later_snapshot) do
    bn = neighborhood(before)
    an = neighborhood(later_snapshot)

    old_groups =
      old
      |> Enum.reject(fn {id, _} -> Map.has_key?(exact, id) end)
      |> Enum.group_by(fn {_id, value} -> structural_key(value, be, bn) end, &elem(&1, 0))

    new_groups =
      later
      |> Enum.reject(fn {id, _} -> id in Map.values(exact) end)
      |> Enum.group_by(fn {_id, value} -> structural_key(value, ae, an) end, &elem(&1, 0))

    result =
      Enum.reduce(old_groups, exact, fn {key, left}, acc ->
        right = Map.get(new_groups, key, [])

        if length(left) == 1 and length(right) == 1 and elem(key, 1) != nil and
             elem(key, 4) != [] do
          Map.put(acc, hd(left), hd(right))
        else
          acc
        end
      end)

    {result, :possible_structural}
  end

  defp correspondence_row(before, later_snapshot, outcome, resolution, prior, later, reason) do
    old = index(before["entities"])
    new = index(later_snapshot["entities"])
    prior = Enum.sort(prior)
    later = Enum.sort(later)

    data = %{
      "outcome" => outcome,
      "resolution" => resolution,
      "before_entity_ids" => prior,
      "after_entity_ids" => later,
      "before_refs" => Enum.map(prior, &reference(before, "entity", old[&1])),
      "after_refs" => Enum.map(later, &reference(later_snapshot, "entity", new[&1])),
      "basis" => reason
    }

    Map.put(data, "id", "correspondence:" <> fingerprint(data))
  end

  defp entity_changes(before, later_snapshot, matches) do
    old = index(before["entities"])
    later = index(later_snapshot["entities"])

    paired =
      Enum.flat_map(matches, fn {prior, next} ->
        before_entity = old[prior]
        after_entity = later[next]

        if before_entity["kind"] in @focus do
          cond do
            semantic_entity(before_entity) != semantic_entity(after_entity) or
                source_witness(before, before_entity) !=
                  source_witness(later_snapshot, after_entity) ->
              [
                change(
                  before,
                  later_snapshot,
                  before_entity["kind"],
                  "modified",
                  before_entity,
                  after_entity,
                  "entity",
                  "source syntax/entity role or normalized source witness changed"
                )
              ]

            before_entity["evidence_ids"] != after_entity["evidence_ids"] ->
              [
                change(
                  before,
                  later_snapshot,
                  before_entity["kind"],
                  "anchor_only",
                  before_entity,
                  after_entity,
                  "entity",
                  "same unique typed source graph; source bytes may differ; runtime unchanged is not proven"
                )
              ]

            true ->
              []
          end
        else
          []
        end
      end)

    removals =
      old
      |> Enum.reject(fn {id, obj} -> Map.has_key?(matches, id) or obj["kind"] not in @focus end)
      |> Enum.map(fn {_id, obj} ->
        change(
          before,
          later_snapshot,
          obj["kind"],
          "removed",
          obj,
          nil,
          "entity",
          "unmatched source record; absence not runtime proof"
        )
      end)

    additions =
      later
      |> Enum.reject(fn {id, obj} -> id in Map.values(matches) or obj["kind"] not in @focus end)
      |> Enum.map(fn {_id, obj} ->
        change(
          before,
          later_snapshot,
          obj["kind"],
          "added",
          nil,
          obj,
          "entity",
          "unmatched source record; execution not proven"
        )
      end)

    paired ++ removals ++ additions
  end

  defp semantic_entity(obj),
    do: Map.take(obj, ~w(kind label semantic_key epistemic_status limitations))

  defp source_witness(snapshot, object) do
    evidence = index(snapshot["evidence"])

    object["evidence_ids"]
    |> Enum.map(&evidence[&1]["basis"])
    |> Enum.sort()
  end

  defp relation_changes(before, later_snapshot, matches) do
    old = index(before["relations"])
    later = index(later_snapshot["relations"])

    # An edge is joinable only if its endpoints already have corroborated
    # entity matches. Equal labels/semantic keys do not authorize an edge join.
    exact =
      old
      |> Map.keys()
      |> Enum.filter(fn id ->
        r = old[id]
        new = later[id]
        not is_nil(new) and joinable?(r, new, matches)
      end)
      |> Map.new(&{&1, &1})

    pairs = extend_relations(exact, old, later, matches)

    paired =
      Enum.flat_map(pairs, fn {prior, next} ->
        before_relation = old[prior]
        after_relation = later[next]
        kind = relation_type(before_relation)

        paired_relation_changes(
          before,
          later_snapshot,
          before_relation,
          after_relation,
          kind,
          matches
        )
      end)

    removals =
      old
      |> Enum.reject(fn {id, _} -> Map.has_key?(pairs, id) end)
      |> Enum.flat_map(fn {_id, r} ->
        case relation_type(r) do
          nil ->
            []

          kind ->
            [
              change(
                before,
                later_snapshot,
                kind,
                "removed",
                r,
                nil,
                "relation",
                "unmatched source relation; performer/transition not observed"
              )
            ]
        end
      end)

    additions =
      later
      |> Enum.reject(fn {id, _} -> id in Map.values(pairs) end)
      |> Enum.flat_map(fn {_id, r} ->
        case relation_type(r) do
          nil ->
            []

          kind ->
            [
              change(
                before,
                later_snapshot,
                kind,
                "added",
                nil,
                r,
                "relation",
                "new proposed source relation; performer/transition not observed"
              )
            ]
        end
      end)

    paired ++ removals ++ additions
  end

  defp joinable?(r, next, matches) do
    matches[r["source_id"]] == next["source_id"] and
      ((is_nil(r["target_id"]) and is_nil(next["target_id"])) or
         (not is_nil(r["target_id"]) and matches[r["target_id"]] == next["target_id"]))
  end

  defp extend_relations(exact, old, later, matches) do
    prior =
      old
      |> Enum.reject(fn {id, r} ->
        Map.has_key?(exact, id) or
          not Map.has_key?(matches, r["source_id"]) or
          (not is_nil(r["target_id"]) and not Map.has_key?(matches, r["target_id"]))
      end)
      |> Enum.group_by(fn {_id, r} -> relation_signature(r, matches) end, &elem(&1, 0))

    next =
      later
      |> Enum.reject(fn {id, _} -> id in Map.values(exact) end)
      |> Enum.group_by(fn {_id, r} -> relation_signature(r, %{}) end, &elem(&1, 0))

    Enum.reduce(prior, exact, fn {key, left}, result ->
      right = Map.get(next, key, [])

      if length(left) == 1 and length(right) == 1 do
        Map.put(result, hd(left), hd(right))
      else
        result
      end
    end)
  end

  defp relation_signature(r, matches) do
    %{
      "kind" => r["kind"],
      "resolution" => r["resolution"],
      "epistemic_status" => r["epistemic_status"],
      "rationale" => r["rationale"],
      "source_id" => Map.get(matches, r["source_id"], r["source_id"]),
      "target_id" =>
        if(is_nil(r["target_id"]),
          do: nil,
          else: Map.get(matches, r["target_id"], r["target_id"])
        )
    }
  end

  defp relation_type(%{"kind" => "performs_effect", "resolution" => "unresolved"}),
    do: "effect_performer_unknown"

  defp relation_type(r), do: Map.get(@relation_types, r["kind"])

  defp reference(snapshot, kind, record) do
    %{
      "provider" => "beamcompass",
      "snapshot_schema_version" => 2,
      "project_id" => snapshot["project_id"],
      "snapshot_id" => snapshot["snapshot_id"],
      "object_kind" => kind,
      "object_id" => record["id"],
      "evidence_ids" => record["evidence_ids"]
    }
  end

  defp change(before, later_snapshot, kind, operation, prior, next, object_kind, reason) do
    data = %{
      "kind" => kind,
      "operation" => operation,
      "before_ref" => if(prior, do: reference(before, object_kind, prior)),
      "after_ref" => if(next, do: reference(later_snapshot, object_kind, next)),
      "before_evidence_ids" => if(prior, do: prior["evidence_ids"], else: []),
      "after_evidence_ids" => if(next, do: next["evidence_ids"], else: []),
      "affected_before_ids" => if(prior, do: adjacent(before, object_kind, prior), else: []),
      "affected_after_ids" => if(next, do: adjacent(later_snapshot, object_kind, next), else: []),
      "basis" => reason,
      "epistemic_status" => "source_possible",
      "semantic_change" => operation != "anchor_only"
    }

    Map.put(data, "id", "change:" <> fingerprint(data))
  end

  defp adjacent(_snapshot, "relation", rel) do
    [rel["id"], rel["source_id"], rel["target_id"]] |> Enum.reject(&is_nil/1) |> Enum.sort()
  end

  defp adjacent(snapshot, "entity", obj) do
    related =
      snapshot["relations"]
      |> Enum.filter(&(obj["id"] in [&1["source_id"], &1["target_id"]]))
      |> Enum.map(& &1["id"])

    Enum.sort([obj["id"] | related])
  end

  defp affected(changes, side) do
    changes
    |> Enum.filter(& &1["semantic_change"])
    |> Enum.flat_map(& &1["affected_#{side}_ids"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp unmatched_groups(unresolved_old, unresolved_new, old, later, be, ae) do
    Enum.reduce(unresolved_old, %{}, fn id, acc ->
      object = old[id]

      Map.update(acc, {object["kind"], path(object, be)}, {[id], []}, &prepend_old(&1, id))
    end)
    |> then(fn acc ->
      Enum.reduce(unresolved_new, acc, fn id, result ->
        object = later[id]

        Map.update(result, {object["kind"], path(object, ae)}, {[], [id]}, &prepend_new(&1, id))
      end)
    end)
  end

  defp paired_relation_changes(
         before,
         later_snapshot,
         before_relation,
         after_relation,
         kind,
         matches
       ) do
    cond do
      is_nil(kind) ->
        []

      relation_signature(before_relation, matches) != relation_signature(after_relation, %{}) ->
        [
          change(
            before,
            later_snapshot,
            kind,
            "modified",
            before_relation,
            after_relation,
            "relation",
            "linked relation kind/status/rationale changed"
          )
        ]

      before_relation["evidence_ids"] != after_relation["evidence_ids"] ->
        [
          change(
            before,
            later_snapshot,
            kind,
            "anchor_only",
            before_relation,
            after_relation,
            "relation",
            "same graph edge and resolution; different source evidence anchors"
          )
        ]

      true ->
        []
    end
  end

  defp ambiguity_kind(left, right) do
    cond do
      length(left) == 1 and length(right) == 1 -> "rename_candidate"
      length(left) == 1 -> "split_candidate"
      length(right) == 1 -> "merge_candidate"
      true -> "ambiguous"
    end
  end

  defp prepend_old({left, right}, id), do: {[id | left], right}
  defp prepend_new({left, right}, id), do: {left, [id | right]}
end
