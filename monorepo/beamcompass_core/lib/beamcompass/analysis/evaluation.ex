defmodule BeamCompass.Analysis.Evaluation do
  @moduledoc """
  Cross-snapshot evaluation against independently specified, exact typed source
  change expectations. Matching is by operation, type, before/after labels and
  evidence-backed paths, not counts or self-described success. An unmatched
  predicted change is a false positive; an unmatched oracle is a false negative.

  Review records are validation inputs, not evidence that a human actually
  reviewed them. Independent human provenance must be checked outside this
  source parser before a phase can claim `human_reviewed_count`.
  """

  alias BeamCompass.Analysis.ChangeSet
  alias BeamCompass.Behavior.Validator
  alias BeamCompass.Json
  alias BeamCompass.Source.Provenance

  @change_fields Enum.sort(~w(kind operation before_label after_label before_path after_path))
  @question_fields Enum.sort(~w(id question expected_targets unknown_expected source_reference))
  @review_fields Enum.sort(
                   ~w(question_id reviewer_id reviewed_at rationale oracle_sha256 evidence_path)
                 )
  @hex ~r/\A[0-9a-f]{64}\z/

  @doc "Reconstruct measured TP/FP/FN and uncertainty from a checked independent oracle."
  @spec measure(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def measure(before, later_snapshot, oracle) do
    with :ok <- validate_oracle(oracle),
         :ok <- Validator.validate(before),
         :ok <- Validator.validate(later_snapshot) do
      started = System.monotonic_time(:microsecond)

      with {:ok, change_set} <- ChangeSet.compare(before, later_snapshot) do
        predicted = Enum.map(change_set["changes"], &change_signature(&1, before, later_snapshot))
        expected = oracle["expected_changes"]
        tp = MapSet.intersection(MapSet.new(expected), MapSet.new(predicted)) |> MapSet.size()
        fp = length(predicted) - tp
        fn_count = length(expected) - tp
        correspondence = change_set["correspondence"]

        unknown = Enum.count(correspondence, &unknown_correspondence?/1)

        unknown_rate = fraction(unknown, length(correspondence))
        expected_unknown = oracle["expected_unknown_min"]

        {:ok,
         %{
           "format" => "beamcompass.change-evaluation",
           "schema_version" => 1,
           "case_id" => oracle["case_id"],
           "before_snapshot_id" => before["snapshot_id"],
           "after_snapshot_id" => later_snapshot["snapshot_id"],
           "true_positive" => tp,
           "false_positive" => fp,
           "false_negative" => fn_count,
           "precision" => fraction(tp, tp + fp),
           "recall" => fraction(tp, tp + fn_count),
           "unknown_count" => unknown,
           "unknown_rate" => unknown_rate,
           "unknown_expectation_met" => unknown >= expected_unknown,
           "false_confidence" => fp,
           "elapsed_microseconds" => System.monotonic_time(:microsecond) - started,
           "expected" => expected,
           "predicted" => Enum.sort(predicted),
           "change_set_id" => change_set["change_set_id"],
           "epistemic_status" => "source_possible"
         }}
      end
    end
  end

  @doc "Validate the 20+ source question records and their externally supplied review references."
  @spec corpus(map(), list(map()), list(map())) :: {:ok, map()} | {:error, term()}
  def corpus(snapshot, questions, reviews) do
    with :ok <- Validator.validate(snapshot),
         true <- is_list(questions) and length(questions) >= 20,
         true <- is_list(reviews),
         :ok <- validate_questions(snapshot, questions),
         :ok <- validate_reviews(questions, reviews) do
      {:ok,
       %{
         "format" => "beamcompass.question-review-inventory",
         "schema_version" => 1,
         "snapshot_id" => snapshot["snapshot_id"],
         "questions" => length(questions),
         "review_records_supplied" => length(reviews),
         "human_reviewed_count" => 0,
         "human_review_verification" => "requires_independent_provenance_audit"
       }}
    else
      false -> {:error, :insufficient_or_malformed_corpus}
      error -> error
    end
  end

  defp validate_oracle(oracle) when is_map(oracle) do
    expected = oracle["expected_changes"]

    if Enum.sort(Map.keys(oracle)) == ~w(case_id expected_changes expected_unknown_min) and
         nonempty_string?(oracle["case_id"]) and
         is_integer(oracle["expected_unknown_min"]) and oracle["expected_unknown_min"] >= 0 and
         is_list(expected) and expected != [] and
         Enum.all?(expected, &valid_oracle_row?/1) and expected == Enum.sort(Enum.uniq(expected)) do
      :ok
    else
      {:error, :invalid_independent_change_oracle}
    end
  end

  defp validate_oracle(_), do: {:error, :invalid_independent_change_oracle}

  defp change_signature(entry, before, later_snapshot) do
    {before_label, before_path} = object_identity(entry["before_ref"], before)
    {after_label, after_path} = object_identity(entry["after_ref"], later_snapshot)

    %{
      "kind" => entry["kind"],
      "operation" => entry["operation"],
      "before_label" => before_label,
      "after_label" => after_label,
      "before_path" => before_path,
      "after_path" => after_path
    }
  end

  defp object_identity(nil, _), do: {nil, nil}

  defp object_identity(reference, snapshot) do
    group = if(reference["object_kind"] == "entity", do: "entities", else: "relations")
    object = Enum.find(snapshot[group], &(&1["id"] == reference["object_id"]))
    ev = Map.new(snapshot["evidence"], &{&1["id"], &1})
    paths = object["evidence_ids"] |> Enum.map(&get_in(ev, [&1, "anchor", "path"])) |> Enum.uniq()

    path =
      case paths do
        [unique] -> unique
        _ -> nil
      end

    label =
      if reference["object_kind"] == "entity" do
        object["label"]
      else
        object["kind"] <> ":" <> object["source_id"] <> "->" <> (object["target_id"] || "unknown")
      end

    {label, path}
  end

  defp validate_questions(snapshot, questions) do
    ids = if Enum.all?(questions, &is_map/1), do: Enum.map(questions, & &1["id"]), else: []

    object_ids =
      MapSet.new(Enum.map(snapshot["entities"] ++ snapshot["relations"], & &1["id"]))

    signatures =
      if length(ids) == length(questions) do
        Enum.map(questions, &question_signature/1)
      else
        []
      end

    if length(ids) == length(questions) and Enum.all?(ids, &is_binary/1) and
         ids == Enum.sort(Enum.uniq(ids)) and
         length(signatures) == length(Enum.uniq(signatures)) and
         Enum.all?(questions, &valid_question?(&1, snapshot, object_ids)) do
      :ok
    else
      {:error, :invalid_question_corpus}
    end
  end

  defp validate_reviews(questions, reviews) do
    ids = MapSet.new(Enum.map(questions, & &1["id"]))
    names = if Enum.all?(reviews, &is_map/1), do: Enum.map(reviews, & &1["question_id"]), else: []

    if length(names) == length(reviews) and Enum.all?(names, &is_binary/1) and
         names == Enum.sort(Enum.uniq(names)) and
         Enum.all?(reviews, &valid_review?(&1, questions, ids)) do
      :ok
    else
      {:error, :invalid_review_provenance}
    end
  end

  defp unknown_correspondence?(entry) do
    entry["resolution"] in ["unknown", "uncertain", "possible_structural"]
  end

  defp valid_oracle_row?(row) do
    valid_change_fields?(row) and
      row["kind"] in ~w(transition effect_intent effect failure_boundary decision effect_performer effect_performer_unknown effect_site_candidate) and
      row["operation"] in ~w(added removed modified anchor_only) and
      (is_binary(row["before_path"]) or is_binary(row["after_path"]))
  end

  defp valid_question?(item, snapshot, object_ids) do
    is_map(item) and Enum.sort(Map.keys(item)) == @question_fields and
      valid_question_identity?(item) and
      is_list(item["expected_targets"]) and
      item["expected_targets"] == Enum.sort(Enum.uniq(item["expected_targets"])) and
      Enum.all?(item["expected_targets"], &MapSet.member?(object_ids, &1)) and
      is_boolean(item["unknown_expected"]) and
      match?({:ok, _}, Validator.validate_reference(snapshot, item["source_reference"]))
  end

  defp valid_review?(review, questions, ids) do
    is_map(review) and Enum.sort(Map.keys(review)) == @review_fields and
      MapSet.member?(ids, review["question_id"]) and
      review["oracle_sha256"] ==
        Provenance.sha256(Json.encode(Enum.find(questions, &(&1["id"] == review["question_id"])))) and
      Enum.all?(~w(reviewer_id reviewed_at rationale evidence_path), fn field ->
        is_binary(review[field]) and String.trim(review[field]) != ""
      end) and
      valid_review_path?(review) and
      match?({:ok, _date, _offset}, DateTime.from_iso8601(review["reviewed_at"]))
  end

  defp valid_change_fields?(row) do
    is_map(row) and Enum.sort(Map.keys(row)) == @change_fields and
      Enum.all?(Map.values(row), &(is_nil(&1) or is_binary(&1)))
  end

  defp valid_question_identity?(item) do
    is_binary(item["id"]) and is_map(item["question"]) and
      item["question"]["id"] == item["id"] and
      item["question"]["kind"] in ~w(message_receivers state_writes effect_intents effect_sites intent_interpreters failure_restarts) and
      is_binary(item["question"]["subject"])
  end

  defp valid_review_path?(review) do
    is_binary(review["oracle_sha256"]) and Regex.match?(@hex, review["oracle_sha256"]) and
      not String.starts_with?(review["evidence_path"], "/") and
      not String.contains?(review["evidence_path"], "..")
  end

  defp question_signature(item) do
    question = item["question"]

    if is_map(question) do
      {question["kind"], question["subject"], item["expected_targets"], item["unknown_expected"],
       item["source_reference"]}
    end
  end

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp fraction(_numerator, 0), do: 0.0
  defp fraction(numerator, denominator), do: numerator / denominator
end
