defmodule BeamCompass.Analysis.QuestionAudit do
  @moduledoc """
  Headless, source-only question answers and independently authored oracle metrics.

  Question targets are real typed relation endpoints, not the presence of a
  relation KIND anywhere in a project. An oracle may deliberately expect zero
  targets; unsupported answers are `unknown`, never proof of nonexistence.
  Results distinguish candidate links from syntactic effect sites. This is an
  evaluation tool, not a natural-language engine or runtime state estimator.
  """

  alias BeamCompass.Behavior.Validator

  @kinds %{
    "message_receivers" => "may_deliver_to",
    "state_writes" => "updates_state",
    "effect_intents" => "describes_effect",
    "effect_sites" => "performs_effect",
    "intent_interpreters" => "causally_related",
    "failure_restarts" => "may_restart"
  }
  @query_keys ~w(id kind subject)
  @oracle_keys ~w(expected_targets query unknown_expected)

  @spec answer(map(), map()) :: {:ok, map()} | {:error, term()}
  def answer(snapshot, question) do
    with :ok <- Validator.validate(snapshot),
         :ok <- validate_query(question) do
      {:ok, answer_validated(snapshot, question)}
    end
  end

  @spec benchmark(map(), list(map())) :: {:ok, map()} | {:error, term()}
  def benchmark(snapshot, oracles) when is_list(oracles) do
    with :ok <- Validator.validate(snapshot),
         :ok <- validate_oracles(oracles) do
      results = Enum.map(oracles, &score(snapshot, &1))
      metrics = totals(results)

      {:ok, %{
        "format" => "beamcompass.question.benchmark",
        "schema_version" => 1,
        "snapshot_schema_version" => 2,
        "project_id" => snapshot["project_id"],
        "snapshot_id" => snapshot["snapshot_id"],
        "results" => results,
        "metrics" => metrics,
        "limitations" => [
          "Oracle is human-authored, source-scoped, and cannot establish runtime truth",
          "Unknown means insufficient evidence, never that behavior is absent"
        ]
      }}
    end
  end

  def benchmark(_, _), do: {:error, :invalid_question_oracles}

  defp validate_query(query) when is_map(query) do
    if Enum.sort(Map.keys(query)) == @query_keys and
         is_binary(query["id"]) and byte_size(query["id"]) > 0 and
         is_binary(query["subject"]) and byte_size(query["subject"]) > 0 and
         Map.has_key?(@kinds, query["kind"]) do
      :ok
    else
      {:error, :invalid_source_question}
    end
  end

  defp validate_query(_), do: {:error, :invalid_source_question}

  defp validate_oracles(oracles) do
    ids = Enum.map(oracles, fn entry ->
      if is_map(entry) and is_map(entry["query"]), do: entry["query"]["id"], else: nil
    end)

    valid =
      oracles != [] and ids == (ids |> Enum.uniq() |> Enum.sort()) and
        Enum.all?(oracles, fn oracle ->
          is_map(oracle) and Enum.sort(Map.keys(oracle)) == @oracle_keys and
            validate_query(oracle["query"]) == :ok and
            is_boolean(oracle["unknown_expected"]) and
            sorted_text?(oracle["expected_targets"])
        end)

    if valid, do: :ok, else: {:error, :invalid_question_oracles}
  end

  defp sorted_text?(items) when is_list(items) do
    Enum.all?(items, &(is_binary(&1) and byte_size(&1) > 0)) and
      items == (items |> Enum.uniq() |> Enum.sort())
  end

  defp sorted_text?(_), do: false

  defp answer_validated(snapshot, query) do
    entities = Map.new(snapshot["entities"], &{&1["id"], &1})
    relation_kind = Map.fetch!(@kinds, query["kind"])

    selected =
      Enum.filter(snapshot["relations"], fn relation ->
        source = entities[relation["source_id"]]
        matches_source?(source, query) and
          relation["kind"] == relation_kind and
          relation["resolution"] != "unresolved" and
          not is_nil(relation["target_id"]) and
          (query["kind"] != "intent_interpreters" or source["kind"] == "effect_intent")
      end)

    unknown =
      Enum.filter(snapshot["relations"], fn relation ->
        relation["resolution"] == "unresolved" and
          (matches_source?(entities[relation["source_id"]], query) or
             (query["kind"] == "intent_interpreters" and
                String.starts_with?(entities[relation["source_id"]]["label"], query["subject"] <> " · "))) and
          relevant_unknown?(relation["kind"], query["kind"])
      end)

    state =
      cond do
        selected == [] -> "unknown"
        Enum.any?(selected, &(&1["resolution"] == "possible")) -> "source_possible"
        true -> "source_syntactic"
      end

    %{
      "id" => query["id"],
      "question" => query,
      "status" => state,
      "answers" => Enum.map(selected, fn relation ->
        %{
          "relation" => source_ref(snapshot, "relation", relation),
          "source" => source_ref(snapshot, "entity", entities[relation["source_id"]]),
          "target" => source_ref(snapshot, "entity", entities[relation["target_id"]]),
          "target_label" => entities[relation["target_id"]]["label"],
          "resolution" => relation["resolution"]
        }
      end),
      "unknown" => Enum.map(unknown, &source_ref(snapshot, "relation", &1)),
      "limitations" => ["Source syntax alone does not prove execution or absence"]
    }
  end

  defp matches_source?(source, query) do
    source_kind = if(query["kind"] == "intent_interpreters", do: "effect_intent", else: nil)

    not is_nil(source) and
      (is_nil(source_kind) or source["kind"] == source_kind) and
      String.starts_with?(source["label"], query["subject"] <> " · ")
  end

  defp relevant_unknown?(relation, question) do
    case question do
      "message_receivers" -> relation == "sends"
      "effect_sites" -> relation == "performs_effect"
      "effect_intents" -> relation == "performs_effect"
      "intent_interpreters" -> relation in ~w(performs_effect calls sends)
      "state_writes" -> relation == "calls"
      "failure_restarts" -> relation in ~w(supervises may_restart)
    end
  end

  defp source_ref(snapshot, kind, record) do
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

  defp score(snapshot, oracle) do
    answer = answer_validated(snapshot, oracle["query"])
    targets = answer["answers"] |> Enum.map(& &1["target_label"]) |> Enum.uniq() |> Enum.sort()
    expected = oracle["expected_targets"]
    # Greedy one-to-one oracle assignment; a broad substring must not count
    # two distinct predicted effects as two true positives for one gold target.
    {unmatched_targets, true_positive} =
      Enum.reduce(expected, {targets, 0}, fn needle, {remaining, count} ->
        case Enum.find(remaining, &String.contains?(&1, needle)) do
          nil -> {remaining, count}
          label -> {List.delete(remaining, label), count + 1}
        end
      end)

    false_positive = length(unmatched_targets)
    false_negative = length(expected) - true_positive
    reported_unknown = answer["status"] in ["unknown", "source_possible"] or answer["unknown"] != []
    unknown_correct = reported_unknown == oracle["unknown_expected"]

    %{
      "id" => oracle["query"]["id"],
      "oracle" => oracle,
      "answer" => answer,
      "actual_targets" => targets,
      "true_positive" => true_positive,
      "false_positive" => false_positive,
      "false_negative" => false_negative,
      "unknown_correct" => unknown_correct,
      "pass" => false_positive == 0 and false_negative == 0 and unknown_correct
    }
  end

  defp totals(results) do
    tp = Enum.sum(Enum.map(results, & &1["true_positive"]))
    fp = Enum.sum(Enum.map(results, & &1["false_positive"]))
    fn_count = Enum.sum(Enum.map(results, & &1["false_negative"]))
    unknown_count = Enum.count(results, fn item ->
      item["answer"]["status"] in ["unknown", "source_possible"] or
        item["answer"]["unknown"] != []
    end)

    %{
      "questions" => length(results),
      "passed" => Enum.count(results, & &1["pass"]),
      "true_positive" => tp,
      "false_positive" => fp,
      "false_negative" => fn_count,
      "precision" => fraction(tp, tp + fp),
      "recall" => fraction(tp, tp + fn_count),
      "false_positive_rate" => fraction(fp, tp + fp),
      "unknown_rate" => fraction(unknown_count, length(results)),
      "unknown_expectation_mismatches" => Enum.count(results, &(not &1["unknown_correct"]))
    }
  end

  defp fraction(_n, 0), do: 0.0
  defp fraction(n, d), do: n / d
end
