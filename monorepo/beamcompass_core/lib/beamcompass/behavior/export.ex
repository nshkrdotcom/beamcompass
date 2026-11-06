defmodule BeamCompass.Behavior.Export do
  @moduledoc """
  Builds an independent source-only v2 graph from a *fresh* provenance-bearing scan.

  It does not upgrade v1 Snapshot, evaluate the target, resolve aliases/macros,
  or infer interpreter execution from names or returned intent constructors.
  """

  alias BeamCompass.Behavior.{Entity, Evidence, Relation, Validator}
  alias BeamCompass.Id
  alias BeamCompass.Json
  alias BeamCompass.Source.Provenance
  alias BeamCompass.Source.Providers.Quoted

  @provider_id "provider:elixir-ast"

  @limitations Enum.sort([
                 "AST syntax is not runtime reachability, execution or evidence of absence",
                 "Call aliases, dynamic dispatch and message recipients may be unresolved",
                 "End locations are unknown; all source anchors have start-only precision",
                 "Intent constructors are proposals, never performer links",
                 "State ownership and Map updates are syntactic candidates, not OTP state proofs"
               ])

  @spec scan(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def scan(path, project_id) when is_binary(path) and is_binary(project_id) do
    with {:ok, context} <- Provenance.scan(path) do
      entries =
        context.sources
        |> Enum.flat_map(fn source -> Enum.map(source.facts, &entry(&1, source)) end)

      extras = Enum.flat_map(entries, &auxiliary_entity/1)
      pairs = Enum.flat_map(entries, &relations_for(&1, entries))

      entities =
        entries
        |> Enum.map(& &1.entity)
        |> Enum.reject(&is_nil/1)
        |> Kernel.++(extras)
        |> Enum.map(&record/1)
        |> Enum.uniq_by(& &1["id"])
        |> Enum.sort_by(& &1["id"])

      relations = pairs |> Enum.map(&elem(&1, 0)) |> Enum.map(&record/1)
      relations = relations |> Enum.uniq_by(& &1["id"]) |> Enum.sort_by(& &1["id"])

      evidence =
        entries
        |> Enum.map(& &1.evidence)
        |> Kernel.++(Enum.map(pairs, &elem(&1, 1)))
        |> Enum.map(&record/1)
        |> Enum.uniq_by(& &1["id"])
        |> Enum.sort_by(& &1["id"])

      issues =
        context.sources
        |> Enum.filter(&(not is_nil(&1.issue)))
        |> Enum.map(fn source ->
          %{
            "code" => "parse_error",
            "message" => "#{source.path}: #{source.issue}",
            "evidence_ids" => []
          }
        end)
        |> Enum.sort_by(&{&1["code"], &1["message"], &1["evidence_ids"]})

      body = %{
        "format" => "beamcompass.snapshot",
        "schema_version" => 2,
        "project_id" => project_id,
        "manifest" => %{
          "source_revision" => nil,
          "source_digest" => context.source_digest,
          "config_digest" => context.config_digest,
          "toolchain" => context.toolchain,
          "providers" => [Quoted.identity()]
        },
        "entities" => entities,
        "relations" => relations,
        "evidence" => evidence,
        "issues" => issues,
        "limitations" => @limitations
      }

      snapshot = Map.put(body, "snapshot_id", Provenance.sha256(Json.encode(body)))

      case Validator.validate(snapshot) do
        :ok ->
          {:ok,
           %{
             snapshot: snapshot,
             inputs: context.inputs,
             settings: context.settings
           }}

        {:error, reason} ->
          {:error, {:invalid_source_export, reason}}
      end
    end
  end

  defp entry(fact, source) do
    evidence = %Evidence{
      id:
        "evidence:" <>
          Id.for_parts([
            "v2",
            source.path,
            fact.id,
            source.sha256,
            fact.anchor["line"],
            fact.anchor["column"]
          ]),
      provider_id: @provider_id,
      mode: "source",
      anchor: %{
        "path" => source.path,
        "source_sha256" => source.sha256,
        "start_line" => fact.anchor["line"],
        "start_column" => fact.anchor["column"],
        "end_line" => nil,
        "end_column" => nil
      },
      basis: "nonexecuting quoted AST: #{fact.kind} syntactic occurrence",
      input_evidence_ids: []
    }

    %{
      fact: fact,
      project: source.project,
      path: source.path,
      evidence: evidence,
      entity: entity_for(fact, source.project, evidence.id)
    }
  end

  defp entity_for(fact, project, evidence_id) do
    kind = entity_kind(fact)

    if is_nil(kind) do
      nil
    else
      proposed? = kind in ["effect_intent", "state_holder", "transition"]

      limitations =
        case kind do
          "effect" ->
            ["explicit syntactic call site only; effect not proven executed"]

          "effect_intent" ->
            ["constructor/tag suggests intent; execution and interpretation unknown"]

          "transition" ->
            ["Map operation does not prove process-state transition"]

          "actor" ->
            ["OTP role declaration, not proven live process"]

          _ ->
            ["source declaration; runtime reachability unverified"]
        end

      %Entity{
        id: entity_id(kind, fact.id),
        kind: kind,
        label: "#{fact.subject} · #{fact.object}",
        semantic_key: semantic_key(kind, fact, project),
        epistemic_status: if(proposed?, do: "proposed", else: "sourced"),
        evidence_ids: [evidence_id],
        limitations: Enum.sort(limitations)
      }
    end
  end

  defp entity_kind(%{kind: :module}), do: "module"
  defp entity_kind(%{kind: :function}), do: "function"
  defp entity_kind(%{kind: :role}), do: "actor"
  defp entity_kind(%{kind: :handler}), do: "trigger"
  defp entity_kind(%{kind: :intent_candidate}), do: "effect_intent"
  defp entity_kind(%{kind: :effect_site}), do: "effect"

  defp entity_kind(%{kind: :call, object: object})
       when object in ["Map.put/3", "Map.update/4", "Map.update!/3"],
       do: "transition"

  defp entity_kind(_), do: nil

  defp semantic_key(kind, fact, project) when kind in ["module", "function"] do
    "#{project}:#{kind}:#{fact.subject}"
  end

  defp semantic_key(_, _, _), do: nil

  defp entity_id(kind, fact_id), do: "entity:" <> Id.for_parts(["v2", kind, fact_id])

  defp auxiliary_entity(%{fact: %{kind: :role} = fact, evidence: evidence}) do
    [
      %Entity{
        id: entity_id("state_holder", fact.id),
        kind: "state_holder",
        label: "#{fact.subject} candidate process state",
        semantic_key: nil,
        epistemic_status: "proposed",
        evidence_ids: [evidence.id],
        limitations: ["role declaration alone cannot establish state ownership"]
      }
    ]
  end

  defp auxiliary_entity(_), do: []

  defp relations_for(%{fact: %{kind: :module}} = entry, entries) do
    entries
    |> Enum.filter(fn item ->
      item.fact.kind == :function and item.path == entry.path and
        module_of(item.fact.subject) == entry.fact.subject
    end)
    |> Enum.map(fn item ->
      relation(
        "implements",
        entry,
        item,
        item,
        "resolved",
        "derived",
        "module and function definitions occur in the same unexpanded source"
      )
    end)
  end

  defp relations_for(%{fact: %{kind: :role} = fact} = entry, _entries) do
    state = %{entry | entity: hd(auxiliary_entity(entry))}

    [
      relation(
        "owns_state",
        entry,
        state,
        entry,
        "possible",
        "proposed",
        "#{fact.object} use suggests a process state holder; actual ownership unverified"
      )
    ]
  end

  defp relations_for(%{fact: %{kind: :handler} = fact} = entry, entries) do
    roles =
      Enum.filter(entries, fn item ->
        item.fact.kind == :role and item.path == entry.path and
          item.fact.subject == module_of(fact.subject)
      end)

    case roles do
      [role] ->
        [
          relation(
            "handles",
            role,
            entry,
            entry,
            "resolved",
            "derived",
            "declared OTP role and syntactic handler clause; runtime dispatch not proven"
          )
        ]

      _ ->
        unresolved_from_function(
          "handles",
          entry,
          entries,
          "no unambiguous actor declaration for handler; dispatch unknown"
        )
    end
  end

  defp relations_for(%{fact: %{kind: :intent_candidate}} = entry, entries) do
    with_function(entry, entries, fn function ->
      [
        relation(
          "describes_effect",
          function,
          entry,
          entry,
          "resolved",
          "proposed",
          "intent constructor/tag occurs in this function; interpretation unverified"
        ),
        relation(
          "performs_effect",
          function,
          nil,
          entry,
          "unresolved",
          "unresolved",
          "constructor is descriptive data, not evidence of an effect performer"
        )
      ]
    end)
  end

  defp relations_for(%{fact: %{kind: :effect_site}} = entry, entries) do
    with_function(entry, entries, fn function ->
      [
        relation(
          "performs_effect",
          function,
          entry,
          entry,
          "resolved",
          "derived",
          "direct explicit effect API call site in the function; runtime execution unproven"
        )
      ]
    end)
  end

  defp relations_for(%{fact: %{kind: :call, object: object}} = entry, entries) do
    with_function(entry, entries, fn function ->
      candidates =
        Enum.filter(entries, fn item ->
          item.fact.kind == :function and item.project == entry.project and
            item.fact.subject == object
        end)

      call =
        case candidates do
          [target] ->
            relation(
              "calls",
              function,
              target,
              entry,
              "resolved",
              "derived",
              "fully qualified source call target uniquely declared in this project"
            )

          _ ->
            relation(
              "calls",
              function,
              nil,
              entry,
              "unresolved",
              "unresolved",
              "call target not uniquely declared in scanned project; may be external, alias or dynamic"
            )
        end

      transitions =
        if not is_nil(entry.entity) and entry.entity.kind == "transition" do
          [
            relation(
              "updates_state",
              function,
              entry,
              entry,
              "resolved",
              "proposed",
              "Map update syntax is a candidate state change, not proof of stored state"
            )
          ]
        else
          []
        end

      [call | transitions]
    end)
  end

  defp relations_for(%{fact: %{kind: :message_send}} = entry, entries) do
    unresolved_from_function(
      "sends",
      entry,
      entries,
      "send/2 syntax found, but recipient and delivery are not statically established"
    )
  end

  defp relations_for(%{fact: %{kind: :unresolved, object: object}} = entry, entries) do
    if String.starts_with?(object, "apply/") do
      unresolved_from_function(
        "calls",
        entry,
        entries,
        "dynamic apply call cannot be safely resolved from source"
      )
    else
      []
    end
  end

  defp relations_for(_, _), do: []

  defp unresolved_from_function(kind, entry, entries, reason) do
    with_function(entry, entries, fn function ->
      [relation(kind, function, nil, entry, "unresolved", "unresolved", reason)]
    end)
  end

  defp with_function(entry, entries, fun) do
    candidates =
      Enum.filter(entries, fn item ->
        item.fact.kind == :function and item.path == entry.path and
          item.fact.subject == entry.fact.subject and
          item.fact.details["clause"] == entry.fact.details["clause"]
      end)

    case candidates do
      [function] -> fun.(function)
      _ -> []
    end
  end

  defp module_of(subject), do: Regex.replace(~r/\.[^.]+\/\d+$/, subject, "")

  defp relation(kind, from, to, anchor, resolution, status, rationale) do
    target_id = if(is_nil(to), do: nil, else: to.entity.id)

    id =
      "relation:" <>
        Id.for_parts(["v2", kind, from.entity.id, target_id || "?", anchor.fact.id, rationale])

    parents =
      [from.evidence.id, anchor.evidence.id] ++
        if(is_nil(to), do: [], else: [to.evidence.id])

    inputs = parents |> Enum.uniq() |> Enum.sort()

    proof = %Evidence{
      id: "evidence:" <> Id.for_parts(["v2", "derivation", id, Enum.join(inputs, ":")]),
      provider_id: @provider_id,
      mode: "source",
      anchor: anchor.evidence.anchor,
      basis: "source-only #{kind} derivation: #{rationale}",
      input_evidence_ids: inputs
    }

    assertion = %Relation{
      id: id,
      kind: kind,
      source_id: from.entity.id,
      target_id: target_id,
      resolution: resolution,
      epistemic_status: status,
      evidence_ids: [proof.id],
      rationale: rationale
    }

    {assertion, proof}
  end

  defp record(struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
