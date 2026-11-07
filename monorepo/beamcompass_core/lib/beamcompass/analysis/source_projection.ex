defmodule BeamCompass.Analysis.SourceProjection do
  @moduledoc """
  Strict, versioned, source-only v2 question projection.

  `budget` counts only visible typed entity/relation records, not capsule
  summaries, receipts or exact evidence refs. Source-possible traversal is
  deliberately not promoted to runtime causality or proved ordering. Missing
  requested boundaries and budget overflow return an *unsatisfied* receipt.
  """

  alias BeamCompass.Analysis.{CausalCapsules, SemanticWitness}
  alias BeamCompass.Behavior.Validator

  @lenses ~w(behavior effects state failure)
  @boundaries ~w(async decision effect failure intent state trigger unknown)
  @limit 256
  @request_fields ~w(format schema_version snapshot_schema_version project_id snapshot_id lens focus budget preserve)
  @preserve_fields ~w(references boundaries)
  @relation_lenses %{
    "effects" => ~w(calls causally_related describes_effect performs_effect sends may_deliver_to),
    "state" => ~w(calls causally_related handles owns_state updates_state sends may_deliver_to),
    "failure" => ~w(causally_related handles supervises may_restart sends may_deliver_to)
  }
  @entity_lenses %{
    "effects" => ~w(trigger function effect effect_intent),
    "state" => ~w(actor trigger function state_holder transition decision),
    "failure" => ~w(actor trigger function failure_boundary)
  }

  @doc "Construct a closed typed request for a validated v2 source snapshot."
  @spec request(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(snapshot, options \\ []) when is_map(snapshot) and is_list(options) do
    with :ok <- Validator.validate(snapshot),
         :ok <- check_options(options),
         {:ok, lens} <- option_lens(Keyword.get(options, :lens, :behavior)),
         {:ok, boundaries} <- option_boundaries(Keyword.get(options, :boundaries, [])) do
      preserve =
        options
        |> Keyword.get(:preserve, [])
        |> then(fn refs ->
          if is_list(refs) and Enum.all?(refs, &is_map/1) do
            Enum.sort_by(refs, &ref_key/1)
          else
            refs
          end
        end)

      body = %{
        "format" => "beamcompass.projection.request",
        "schema_version" => 1,
        "snapshot_schema_version" => 2,
        "project_id" => snapshot["project_id"],
        "snapshot_id" => snapshot["snapshot_id"],
        "lens" => lens,
        "focus" => Keyword.get(options, :focus),
        "budget" => Keyword.get(options, :budget, 30),
        "preserve" => %{"references" => preserve, "boundaries" => boundaries}
      }

      case validate_request(snapshot, body) do
        :ok -> {:ok, body}
        error -> error
      end
    end
  end

  def request(_, _), do: {:error, :invalid_projection_options}

  @doc "Project validated source-only v2 data with explicit omission receipts."
  @spec project(map(), map()) :: {:ok, map()} | {:error, term()}
  def project(snapshot, request) when is_map(snapshot) and is_map(request) do
    with :ok <- Validator.validate(snapshot),
         :ok <- validate_request(snapshot, request) do
      {:ok, render(snapshot, request)}
    end
  end

  def project(_, _), do: {:error, :invalid_projection_request}

  @doc "Check a typed request against exact snapshot-local source references."
  @spec validate_request(map(), term()) :: :ok | {:error, term()}
  def validate_request(snapshot, request) when is_map(request) do
    with :ok <- ensure(keys?(request, @request_fields), :invalid_projection_request),
         :ok <- ensure(request["format"] == "beamcompass.projection.request", :unsupported_projection_format),
         :ok <- ensure(request["schema_version"] === 1, :unsupported_projection_version),
         :ok <- ensure(request["snapshot_schema_version"] === 2, :unsupported_snapshot_version),
         :ok <- ensure(request["project_id"] == snapshot["project_id"] and
                          request["snapshot_id"] == snapshot["snapshot_id"], :wrong_projection_namespace),
         :ok <- ensure(request["lens"] in @lenses, :unsupported_projection_lens),
         :ok <- ensure(is_integer(request["budget"]) and
                          request["budget"] > 0 and request["budget"] <= @limit,
                        :invalid_projection_budget),
         :ok <- check_focus(snapshot, request["focus"]),
         :ok <- check_preserve(snapshot, request["preserve"]) do
      :ok
    end
  end

  def validate_request(_, _), do: {:error, :invalid_projection_request}

  defp check_options(options) do
    ensure(Keyword.keyword?(options) and
             Keyword.keys(options) -- [:lens, :budget, :focus, :preserve, :boundaries] == [],
           :invalid_projection_options)
  end

  defp option_lens(lens) when is_atom(lens) do
    label = Atom.to_string(lens)
    if label in @lenses, do: {:ok, label}, else: {:error, :unsupported_projection_lens}
  end

  defp option_lens(lens) when is_binary(lens) do
    if lens in @lenses, do: {:ok, lens}, else: {:error, :unsupported_projection_lens}
  end

  defp option_lens(_), do: {:error, :unsupported_projection_lens}

  defp option_boundaries(boundaries) when is_list(boundaries) do
    if Enum.all?(boundaries, &(is_atom(&1) or is_binary(&1))) do
      names = Enum.map(boundaries, &to_string/1)

      if Enum.all?(names, &(&1 in @boundaries)) do
        {:ok, Enum.sort(Enum.uniq(names))}
      else
        {:error, :unsupported_preservation_boundary}
      end
    else
      {:error, :unsupported_preservation_boundary}
    end
  end

  defp option_boundaries(_), do: {:error, :unsupported_preservation_boundary}

  defp check_focus(_snapshot, nil), do: :ok
  defp check_focus(snapshot, ref), do: check_reference(snapshot, ref)

  defp check_preserve(snapshot, preserve) do
    with :ok <- ensure(keys?(preserve, @preserve_fields), :invalid_projection_preserve),
         :ok <- ensure(sorted_set?(preserve["boundaries"]) and
                          Enum.all?(preserve["boundaries"], &(&1 in @boundaries)),
                        :unsupported_preservation_boundary),
         :ok <- ensure(is_list(preserve["references"]), :invalid_projection_preserve),
         :ok <- ensure(sorted_refs?(preserve["references"]), :invalid_projection_preserve) do
      Enum.reduce_while(preserve["references"], :ok, fn ref, :ok ->
        case check_reference(snapshot, ref) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp check_reference(snapshot, ref) when is_map(ref) do
    if ref["object_kind"] in ["entity", "relation"] do
      case Validator.validate_reference(snapshot, ref) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      {:error, :unsupported_projection_reference_kind}
    end
  end

  defp check_reference(_, _), do: {:error, :invalid_projection_reference}

  defp sorted_refs?(refs) when is_list(refs) do
    if Enum.all?(refs, &is_map/1) do
      keys = Enum.map(refs, &ref_key/1)
      keys == (keys |> Enum.uniq() |> Enum.sort())
    else
      false
    end
  end

  defp sorted_refs?(_), do: false
  defp sorted_set?(items) when is_list(items), do: items == (items |> Enum.uniq() |> Enum.sort())
  defp sorted_set?(_), do: false
  defp keys?(map, keys) when is_map(map), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp keys?(_, _), do: false
  defp ensure(true, _), do: :ok
  defp ensure(false, reason), do: {:error, reason}
  defp ref_key(ref), do: "#{ref["object_kind"]}:#{ref["object_id"]}"

  defp records(snapshot) do
    entities = Enum.map(snapshot["entities"], &{"entity:" <> &1["id"], {"entity", &1}})
    relations = Enum.map(snapshot["relations"], &{"relation:" <> &1["id"], {"relation", &1}})
    Map.new(entities ++ relations)
  end

  defp record_ref(snapshot, kind, record) do
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

  defp reference(snapshot, records, key) do
    {kind, record} = Map.fetch!(records, key)
    record_ref(snapshot, kind, record)
  end

  defp capsule_keys(capsule) do
    Enum.map(capsule["entity_ids"], &("entity:" <> &1)) ++
      Enum.map(capsule["relation_ids"], &("relation:" <> &1))
  end

  defp scope(capsules, records, focus) do
    if is_nil(focus) do
      {capsules, Map.keys(records), "project_inventory"}
    else
      key = ref_key(focus)
      containing = Enum.filter(capsules, &(key in capsule_keys(&1)))

      keys =
        case containing do
          [] ->
            # An explicit exact focus outside all bounded handler capsules is
            # still valid, but never presented as a proven trigger slice.
            [key | incident_refs(focus, records)]

          selected ->
            [key | Enum.flat_map(selected, &capsule_keys/1)]
        end

      {containing, Enum.uniq(keys), "focused_source_slice"}
    end
  end

  defp incident_refs(%{"object_kind" => "entity", "object_id" => id}, records) do
    records
    |> Enum.filter(fn
      {_key, {"relation", relation}} ->
        relation["source_id"] == id or relation["target_id"] == id

      _ ->
        false
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp incident_refs(_focus, _records), do: []

  defp boundary?("entity", object, boundary, _entities) do
    case boundary do
      "effect" -> object["kind"] == "effect"
      "intent" -> object["kind"] == "effect_intent"
      "state" -> object["kind"] in ~w(state_holder transition)
      "decision" -> object["kind"] == "decision"
      "failure" -> object["kind"] == "failure_boundary"
      "trigger" -> object["kind"] == "trigger"
      _ -> false
    end
  end

  defp boundary?("relation", object, boundary, entities) do
    case boundary do
      "effect" -> object["kind"] == "performs_effect"
      "intent" ->
        object["kind"] == "describes_effect" or
          (object["kind"] == "causally_related" and
             entities[object["source_id"]]["kind"] == "effect_intent")

      "state" -> object["kind"] in ~w(owns_state updates_state)
      "async" -> object["kind"] in ~w(sends may_deliver_to potentially_concurrent occurs_before)
      "failure" -> object["kind"] in ~w(supervises may_restart)
      "unknown" -> object["resolution"] == "unresolved"
      "trigger" -> object["kind"] == "handles"
      _ -> false
    end
  end

  defp lens_member?(_kind, _object, "behavior"), do: true

  defp lens_member?("entity", object, lens),
    do: object["kind"] in Map.fetch!(@entity_lenses, lens)

  defp lens_member?("relation", object, lens),
    do: object["resolution"] == "unresolved" or
      object["kind"] in Map.fetch!(@relation_lenses, lens)

  defp expand_capsule(snapshot, records, capsule) do
    %{
      "id" => capsule["id"],
      "trigger" => reference(snapshot, records, "entity:" <> capsule["trigger_id"]),
      "members" => refs(snapshot, records, Enum.map(capsule["entity_ids"], &("entity:" <> &1))),
      "relations" => refs(snapshot, records, Enum.map(capsule["relation_ids"], &("relation:" <> &1))),
      "unresolved" => refs(snapshot, records, Enum.map(capsule["unresolved_relation_ids"], &("relation:" <> &1))),
      "cut_relations" => refs(snapshot, records, Enum.map(capsule["cut_relation_ids"], &("relation:" <> &1))),
      "truncated" => capsule["truncated"],
      "coverage" => capsule["coverage"],
      "ordering" => capsule["ordering"]
    }
  end

  defp refs(snapshot, records, keys) do
    keys |> Enum.uniq() |> Enum.sort() |> Enum.map(&reference(snapshot, records, &1))
  end

  defp receipt_entries(snapshot, records, keys, reason) do
    Enum.map(Enum.sort(keys), &%{"reference" => reference(snapshot, records, &1), "reason" => reason})
  end

  # Source-visible records are never independently counted as a complete
  # causal answer. Critical anchors carry an *atomic* relation/endpoint path
  # witness to a syntactic trigger, or an explicit budget/disconnection gap.
  defp render(snapshot, request) do
    records = records(snapshot)
    entity_index = Map.new(snapshot["entities"], &{&1["id"], &1})
    all_capsules = CausalCapsules.build(snapshot)
    {selected_capsules, scoped, scope_label} = scope(all_capsules, records, request["focus"])
    scoped = Enum.sort(scoped)
    focus_key = if(is_nil(request["focus"]), do: [], else: [ref_key(request["focus"])])
    explicit = Enum.map(request["preserve"]["references"], &ref_key/1)
    boundaries = request["preserve"]["boundaries"]

    boundary_hits =
      Map.new(boundaries, fn boundary ->
        hits =
          Enum.filter(scoped, fn key ->
            {kind, record} = Map.fetch!(records, key)
            boundary?(kind, record, boundary, entity_index)
          end)
        {boundary, hits}
      end)

    critical = Enum.uniq(explicit ++ focus_key ++ Enum.flat_map(Map.values(boundary_hits), & &1))

    eligible =
      Enum.filter(scoped, fn key ->
        {kind, record} = Map.fetch!(records, key)
        lens_member?(kind, record, request["lens"])
      end)

    priorities =
      (Enum.sort(Enum.uniq(explicit ++ focus_key)) ++
         Enum.sort(critical -- (explicit ++ focus_key)) ++
         Enum.sort(eligible -- critical))
      |> Enum.uniq()

    plans = SemanticWitness.plan(snapshot, selected_capsules, priorities)
    selected = select_atomic(priorities, plans, request["budget"])
    missing = Enum.sort(critical -- selected)
    missing_boundaries = boundaries |> Enum.filter(&(boundary_hits[&1] == [])) |> Enum.sort()
    witness_gaps = Enum.filter(critical, fn key ->
      not plans[key].connected or Enum.any?(plans[key].members, &(&1 not in selected))
    end)
    cut = Enum.any?(selected_capsules, & &1["truncated"])

    status =
      if missing == [] and missing_boundaries == [] and witness_gaps == [] and not cut,
        do: "satisfied", else: "unsatisfied"

    summarized = Enum.flat_map(selected_capsules, &capsule_keys/1)
    collapsed = Enum.filter((eligible -- selected) -- critical, &(&1 in summarized))
    left = Map.keys(records) -- (selected ++ collapsed)

    omitted =
      Enum.map(left, fn key ->
        reason =
          cond do
            key in critical or key in eligible -> "budget"
            key in scoped -> "lens_filtered"
            true -> "outside_focus"
          end
        %{"reference" => reference(snapshot, records, key), "reason" => reason}
      end)
      |> Enum.sort_by(&ref_key(&1["reference"]))

    unresolved =
      Enum.filter(Enum.uniq(scoped ++ explicit), fn key ->
        match?({"relation", %{"resolution" => "unresolved"}}, records[key])
      end)

    completeness =
      cond do
        status == "unsatisfied" -> "incomplete_preservation"
        snapshot["issues"] != [] -> "source_parse_issues"
        unresolved != [] -> "bounded_source_with_unknowns"
        true -> "bounded_source_only"
      end

    witnesses =
      critical
      |> Enum.sort()
      |> Enum.map(fn key ->
        plan = plans[key]
        preserved = key in selected
        situation =
          cond do
            not preserved -> "budget_lost"
            not plan.connected -> "unconnected"
            Enum.any?(plan.members, &(&1 not in selected)) -> "incomplete_witness"
            true -> "preserved"
          end

        %{
          "requested" => reference(snapshot, records, key),
          "status" => situation,
          "path" => refs(snapshot, records, plan.path),
          "dependency_refs" => refs(snapshot, records, plan.members),
          "path_supported" => plan.connected
        }
      end)

    %{
      "format" => "beamcompass.projection.result",
      "schema_version" => 1,
      "snapshot_schema_version" => 2,
      "project_id" => snapshot["project_id"],
      "snapshot_id" => snapshot["snapshot_id"],
      "request" => request,
      "scope" => scope_label,
      "capsules" => Enum.map(selected_capsules, &expand_capsule(snapshot, records, &1)),
      "visible" => refs(snapshot, records, selected),
      "collapsed" => receipt_entries(snapshot, records, collapsed, "capsule_summary"),
      "omitted" => omitted,
      "unknown" => receipt_entries(snapshot, records, unresolved, "unresolved_source_relation"),
      "receipt" => %{
        "status" => status,
        "completeness" => completeness,
        "requested" => refs(snapshot, records, critical),
        "preserved" => refs(snapshot, records, critical -- missing),
        "unsatisfied" => refs(snapshot, records, missing),
        "missing_boundaries" => missing_boundaries,
        "witnesses" => witnesses,
        "counts" => %{
          "visible" => length(selected),
          "collapsed" => length(collapsed),
          "omitted" => length(omitted),
          "unknown" => length(unresolved),
          "capsules" => length(selected_capsules),
          "scope_excluded" => length((Map.keys(records) -- scoped) -- selected)
        },
        "limitations" => Enum.sort([
          "AST paths are possible source witnesses, not runtime causality or message ordering",
          "No exact source end spans, macro/dataflow proof or negative evidence of effect absence",
          "Critical witness endpoints and links are admitted atomically under a record budget",
          "Disconnected anchors and truncated routes cannot count as semantic preservation",
          "Visible budget excludes expandable capsule metadata, unknowns and receipts"
        ])
      }
    }
  end

  defp select_atomic(priorities, plans, limit) do
    {selected, _count} =
      Enum.reduce(priorities, {%{}, 0}, fn key, {included, size} ->
        group = plans[key].members
        new = Enum.reject(group, &Map.has_key?(included, &1))

        if size + length(new) <= limit do
          {Enum.reduce(new, included, &Map.put(&2, &1, true)), size + length(new)}
        else
          {included, size}
        end
      end)

    selected |> Map.keys() |> Enum.sort()
  end
end
