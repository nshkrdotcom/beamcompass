defmodule BeamCompass.Behavior.Export do
  @moduledoc """
  Builds an independent source-only v2 graph from a *fresh* provenance-bearing scan.

  It does not upgrade v1 Snapshot, evaluate the target, resolve aliases/macros,
  or infer interpreter execution from names or returned intent constructors.
  """

  alias BeamCompass.Behavior.{Entity, Evidence, Relation, Validator}
  alias BeamCompass.Id
  alias BeamCompass.Json
  alias BeamCompass.Source.{CausalHints, Provenance}
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
      direct = Enum.flat_map(entries, &relations_for(&1, entries))

      message_hints =
        Enum.flat_map(context.sources, fn source ->
          Enum.map(source.hints, &Map.put(&1, :path, source.path))
        end)

      hints = Enum.flat_map(message_hints, &message_relations(&1, entries))
      first_pass = direct ++ hints
      pairs = first_pass ++ effect_flow_relations(entries, message_hints, first_pass)

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

  @doc """
  Export a clean, pinned Git source revision without executing target code.
  Git reads only object bytes. Every scanned Elixir path must exactly match the
  given HEAD commit; uncommitted or untracked source changes are refused.
  """
  @spec scan_git(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def scan_git(path, project_id) when is_binary(path) and is_binary(project_id) do
    with {:ok, scanned} <- scan(path, project_id),
         {:ok, head} <- git(path, ["rev-parse", "--verify", "HEAD^{commit}"]),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, String.trim(head)),
         {:ok, top} <- git(path, ["rev-parse", "--show-toplevel"]),
         true <- Path.expand(path) == String.trim(top),
         :ok <- verify_git_blobs(path, String.trim(head), scanned.inputs) do
      manifest = Map.put(scanned.snapshot["manifest"], "source_revision", String.trim(head))
      body = scanned.snapshot |> Map.put("manifest", manifest) |> Map.delete("snapshot_id")
      snapshot = Map.put(body, "snapshot_id", Provenance.sha256(Json.encode(body)))

      with :ok <- Validator.validate(snapshot) do
        {:ok, %{scanned | snapshot: snapshot}}
      end
    else
      false -> {:error, :unverified_git_revision}
      error -> error
    end
  end

  def scan_git(_, _), do: {:error, :invalid_source_path}

  defp verify_git_blobs(path, head, inputs) do
    Enum.reduce_while(inputs, :ok, fn input, _ ->
      case git(path, ["show", "#{head}:#{input["path"]}"]) do
        {:ok, bytes} ->
          verify_blob_hash(bytes, input["sha256"])

        _ ->
          {:halt, {:error, :source_not_in_pinned_git_revision}}
      end
    end)
  end

  defp verify_blob_hash(bytes, expected) do
    if Provenance.sha256(bytes) == expected,
      do: {:cont, :ok},
      else: {:halt, {:error, :uncommitted_source_bytes}}
  end

  defp git(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, _code} -> {:error, :git_revision_unavailable}
    end
  rescue
    ErlangError -> {:error, :git_revision_unavailable}
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
      basis: syntax_witness(fact),
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

  # A bounded normalized source-line witness distinguishes a changed state
  # expression from a pure line shift. It is inert text, not interpreted AST
  # behavior. Existing v1 scans and serialized bytes are unaffected.
  defp syntax_witness(fact) do
    category = entity_kind(fact)
    prefix = "nonexecuting quoted AST: #{fact.kind} syntactic occurrence"

    if category in ["transition", "effect_intent", "effect", "failure_boundary", "decision"] do
      snippet =
        fact.anchor["snippet"]
        |> String.replace(~r/\s+/u, " ")
        |> String.trim()

      prefix <> "; source-line witness: " <> snippet
    else
      prefix
    end
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
  defp entity_kind(%{kind: :transition_candidate}), do: "transition"
  defp entity_kind(%{kind: :decision}), do: "decision"
  defp entity_kind(%{kind: :failure_boundary}), do: "failure_boundary"

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

    ownership =
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

    lexical =
      with_function(entry, entries, fn function ->
        [
          relation(
            "causally_related",
            entry,
            function,
            entry,
            "possible",
            "proposed",
            "handler clause encloses function body; invocation and ordering unverified"
          )
        ]
      end)

    ownership ++ lexical
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

  defp relations_for(%{fact: %{kind: :transition_candidate}} = entry, entries) do
    with_function(entry, entries, fn function ->
      [
        relation(
          "updates_state",
          function,
          entry,
          entry,
          "possible",
          "proposed",
          "literal tuple in a three-part return candidate; stored state and branch execution unverified"
        )
      ]
    end)
  end

  defp relations_for(%{fact: %{kind: :decision}} = entry, entries) do
    with_function(entry, entries, fn function ->
      [
        relation(
          "causally_related",
          function,
          entry,
          entry,
          "possible",
          "proposed",
          "branch syntax within function; no branch outcome or execution order proven"
        )
      ]
    end)
  end

  defp relations_for(%{fact: %{kind: :failure_boundary}} = entry, entries) do
    with_function(entry, entries, fn function ->
      [
        relation(
          "causally_related",
          function,
          entry,
          entry,
          "possible",
          "proposed",
          "source failure/lifecycle syntax; no crash, catch or restart observed"
        )
      ]
    end)
  end

  defp relations_for(%{fact: %{kind: :supervisor_child} = fact} = entry, entries) do
    supervisor =
      Enum.filter(entries, fn item ->
        item.fact.kind == :role and item.path == entry.path and
          item.fact.subject == fact.details["declaring_module"] and
          item.fact.object == "Supervisor"
      end)

    child =
      Enum.filter(entries, fn item ->
        item.fact.kind == :role and item.project == entry.project and
          item.fact.subject == fact.object
      end)

    supervisor_relations(supervisor, child, entry)
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

  defp relations_for(%{fact: %{kind: :message_send} = fact} = entry, entries) do
    unknown =
      unresolved_from_function(
        "sends",
        entry,
        entries,
        "send/2 syntax found, but recipient and delivery are not statically established"
      )

    candidates =
      if fact.details["receiver_expression"] == "self()" do
        Enum.filter(entries, fn item ->
          item.fact.kind == :handler and item.path == entry.path and
            item.fact.subject == "#{module_of(fact.subject)}.handle_info/2" and
            item.fact.object == fact.object
        end)
      else
        []
      end

    candidate =
      case candidates do
        [handler] ->
          with_function(entry, entries, fn function ->
            [
              relation(
                "may_deliver_to",
                function,
                handler,
                entry,
                "possible",
                "proposed",
                "send(self(), payload) matches one local handle_info pattern; delivery/dispatch unknown"
              )
            ]
          end)

        _ ->
          []
      end

    unknown ++ candidate
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

  defp supervisor_relations([owner], [target], entry) do
    [
      relation(
        "supervises",
        owner,
        target,
        entry,
        "possible",
        "proposed",
        "literal Supervisor.init child entry; actual startup/child-spec semantics unverified"
      ),
      relation(
        "may_restart",
        owner,
        target,
        entry,
        "possible",
        "proposed",
        "static supervisor membership only; restart policy/occurrence unverified"
      )
    ]
  end

  defp supervisor_relations([owner], _, entry) do
    [
      relation(
        "supervises",
        owner,
        nil,
        entry,
        "unresolved",
        "unresolved",
        "literal child listed but unique local actor unavailable"
      )
    ]
  end

  defp supervisor_relations(_, _, _), do: []

  # Candidate-only flow: an alias-resolved reducer call inside a sender, a
  # uniquely pattern-matched message handler, and an Enum.each function capture
  # are all required. A tag by itself is NEVER enough to select an executor.
  # The relation's derivation cites all three links, not just the tag.
  defp effect_flow_relations(entries, hints, pairs) do
    relations = Enum.map(pairs, &elem(&1, 0))
    by_id = Map.new(entries, &{if(is_nil(&1.entity), do: nil, else: &1.entity.id), &1})

    candidate_paths = candidate_paths(entries, hints, relations, by_id)

    for intent <- entries,
        intent.fact.kind == :intent_candidate and
          intent.fact.details["basis"] == "tuple_tag",
        {reducer, executor, call_edge, delivery_edge, capture_edge} <- candidate_paths,
        intent.path == reducer.path and intent.fact.subject == reducer.fact.subject and
          intent.fact.details["clause"] == reducer.fact.details["clause"],
        executor_tag?(executor, intent, entries) do
      relation(
        "causally_related",
        intent,
        executor,
        intent,
        "possible",
        "proposed",
        "source candidate: reducer call, self-message callback and Enum.each capture with matching tagged execute clause; value flow/dispatch unverified",
        [call_edge, delivery_edge, capture_edge]
      )
    end
  end

  defp candidate_paths(entries, hints, relations, by_id) do
    for edge <- relations,
        edge.kind == "causally_related" and
          String.contains?(edge.rationale, "direct lexical alias"),
        caller = by_id[edge.source_id],
        reducer = by_id[edge.target_id],
        not is_nil(caller) and not is_nil(reducer),
        tail <- delivery_paths(caller, reducer, entries, hints, relations, by_id),
        do: Tuple.insert_at(tail, 2, edge)
  end

  defp delivery_paths(caller, reducer, entries, hints, relations, by_id) do
    for delivery <- relations,
        delivery.kind == "may_deliver_to" and delivery.source_id == caller.entity.id,
        handler <- entries,
        handler.fact.kind == :handler and handler.entity.id == delivery.target_id,
        {executor, capture} <- captured_executors(handler, entries, relations, by_id),
        compatible_flow_hints?(hints, caller, handler, executor, reducer),
        do: {reducer, executor, delivery, capture}
  end

  defp captured_executors(handler, entries, relations, by_id) do
    for function <- entries,
        same_clause?(function, handler) and function.fact.kind == :function,
        capture <- relations,
        capture.kind == "causally_related" and capture.source_id == function.entity.id,
        String.contains?(capture.rationale, "Enum.each source capture"),
        executor = by_id[capture.target_id],
        not is_nil(executor),
        do: {executor, capture}
  end

  defp same_clause?(left, right) do
    left.path == right.path and left.fact.subject == right.fact.subject and
      left.fact.details["clause"] == right.fact.details["clause"]
  end

  defp compatible_flow_hints?(hints, caller, handler, executor, reducer) do
    bindings = Enum.filter(hints, &binding_hint?(&1, caller, reducer))
    sends = Enum.filter(hints, &send_hint?(&1, caller, handler))
    captures = Enum.filter(hints, &capture_hint?(&1, handler, executor))

    for binding <- bindings,
        variable <- binding.variables,
        send_hint <- sends,
        capture <- captures do
      valid_transfer?(binding, variable, send_hint, capture, handler, hints)
    end
    |> Enum.any?()
  end

  defp valid_transfer?(binding, variable, send_hint, capture, handler, hints) do
    before?(binding, send_hint) and
      not overwritten?(hints, binding, send_hint, variable) and
      not overwritten?(hints, nil, capture, capture.collection) and
      CausalHints.transferred_variable?(
        send_hint.payload,
        handler.fact.object,
        variable,
        capture.collection
      )
  end

  defp before?(left, right), do: {left.line, left.column} < {right.line, right.column}

  defp overwritten?(hints, start, finish, variable) do
    Enum.any?(hints, fn hint ->
      hint.kind in [:assignment, :result_binding] and hint.path == finish.path and
        hint.subject == finish.subject and hint.clause == finish.clause and
        variable in hint.variables and before?(hint, finish) and after_start?(hint, start)
    end)
  end

  defp after_start?(_hint, nil), do: true
  defp after_start?(hint, start), do: before?(start, hint)

  defp hint_clause?(hint, entry) do
    hint.path == entry.path and hint.subject == entry.fact.subject and
      hint.clause == entry.fact.details["clause"]
  end

  defp binding_hint?(hint, caller, reducer) do
    hint.kind == :result_binding and hint_clause?(hint, caller) and
      hint.target == reducer.fact.subject
  end

  defp send_hint?(hint, caller, handler) do
    hint.kind == :send and hint.receiver == "self()" and hint_clause?(hint, caller) and
      CausalHints.payload_matches?(hint.payload, handler.fact.object)
  end

  defp capture_hint?(hint, handler, executor) do
    hint.kind == :capture and hint_clause?(hint, handler) and hint.target == executor.fact.subject
  end

  defp executor_tag?(executor, intent, entries) do
    prefix = "execute({:" <> intent.fact.object

    String.ends_with?(executor.fact.subject, ".execute/1") and
      (String.starts_with?(executor.fact.details["clause"], prefix <> ",") or
         String.starts_with?(executor.fact.details["clause"], prefix <> "}")) and
      Enum.any?(entries, fn site ->
        site.fact.kind in [:effect_site, :message_send] and
          site.path == executor.path and
          site.fact.subject == executor.fact.subject and
          site.fact.details["clause"] == executor.fact.details["clause"]
      end)
  end

  # Match hints to source scanner facts with identical clause AND start anchor.
  # Hints alone never create facts, nor do aliases imply a runtime target.
  defp message_relations(hint, entries) do
    case hint.kind do
      :genserver ->
        messaging_relations(hint, entries, :call)

      :send ->
        messaging_relations(hint, entries, :message_send)

      :alias_call ->
        lexical_relations(
          hint,
          entries,
          "direct lexical alias call; macro expansion/dynamic dispatch unknown"
        )

      :capture ->
        lexical_relations(
          hint,
          entries,
          "Enum.each source capture; invocation/element values unverified"
        )

      _ ->
        []
    end
  end

  defp matching_sites(hint, entries, kind) do
    Enum.filter(entries, fn entry ->
      entry.fact.kind == kind and entry.path == hint.path and
        entry.fact.subject == hint.subject and
        entry.fact.details["clause"] == hint.clause and
        entry.fact.anchor["line"] == hint.line and
        entry.fact.anchor["column"] == hint.column and
        (kind == :message_send or entry.fact.object == hint.call)
    end)
  end

  defp messaging_relations(hint, entries, kind) do
    case matching_sites(hint, entries, kind) do
      [site] ->
        with_function(site, entries, &message_candidates(&1, site, hint, entries, kind))

      _ ->
        []
    end
  end

  defp message_candidates(function, site, hint, entries, kind) do
    unresolved =
      if kind == :call do
        [
          relation(
            "sends",
            function,
            nil,
            site,
            "unresolved",
            "unresolved",
            "GenServer send semantics require runtime address/delivery evidence"
          )
        ]
      else
        []
      end

    target_module =
      if hint.receiver in ["__MODULE__", "self()"], do: hint.module, else: hint.receiver

    candidates = Enum.filter(entries, &message_handler?(&1, site, hint, target_module))
    unresolved ++ unique_delivery(candidates, function, site)
  end

  defp message_handler?(entry, site, hint, target_module) do
    entry.fact.kind == :handler and entry.project == site.project and
      entry.fact.subject == "#{target_module}.#{hint.handler}" and
      CausalHints.payload_matches?(hint.payload, entry.fact.object)
  end

  defp unique_delivery([handler], function, site) do
    [
      relation(
        "may_deliver_to",
        function,
        handler,
        site,
        "possible",
        "proposed",
        "literal address/tag and unique callback pattern; PID, delivery, guard and runtime order unverified"
      )
    ]
  end

  defp unique_delivery(_, _, _), do: []

  defp lexical_relations(hint, entries, rationale) do
    case matching_sites(hint, entries, :call) do
      [site] ->
        with_function(site, entries, &lexical_targets(&1, site, hint, entries, rationale))

      _ ->
        []
    end
  end

  defp lexical_targets(function, site, hint, entries, rationale) do
    entries
    |> Enum.filter(fn entry ->
      entry.fact.kind == :function and entry.project == site.project and
        entry.fact.subject == hint.target
    end)
    |> Enum.map(
      &relation("causally_related", function, &1, site, "possible", "proposed", rationale)
    )
  end

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

  defp relation(kind, from, to, anchor, resolution, status, rationale, witnesses \\ []) do
    target_id = if(is_nil(to), do: nil, else: to.entity.id)

    id =
      "relation:" <>
        Id.for_parts(["v2", kind, from.entity.id, target_id || "?", anchor.fact.id, rationale])

    parents =
      [from.evidence.id, anchor.evidence.id] ++
        if(is_nil(to), do: [], else: [to.evidence.id]) ++
        Enum.flat_map(witnesses, & &1.evidence_ids)

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
