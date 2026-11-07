defmodule BeamCompass.P04AcceptanceTest do
  use ExUnit.Case, async: true

  alias BeamCompass.Analysis.{ChangeSet, Evaluation, Invalidation}
  alias BeamCompass.Behavior.{Archive, Export, Validator}
  alias BeamCompass.Json
  alias BeamCompass.Source.Provenance

  @fixtures Path.expand("../../../fixtures/p04_revisions", __DIR__)
  @cases %{
    base: "base.ex",
    mutated: "mutated.ex",
    shifted: "line_shifted.ex"
  }

  setup do
    root = Path.join(System.tmp_dir!(), "beamcompass_p04_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), "raise \"untrusted Mix cannot execute\"")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "persistent versioned bundles validate source lineage and evolution", %{root: root} do
    {snapshot, inputs} = sample(:base)
    assert :ok = Validator.validate(snapshot)
    assert {:ok, bundle} = Archive.build(snapshot, inputs)
    assert bundle["schema_version"] == 1
    assert bundle["snapshot_schema_version"] == 2
    assert :ok = Archive.validate(bundle)
    assert {:ok, ^snapshot} = Archive.rehydrate(bundle)
    assert {:error, :source_reextraction_required} =
             Archive.migrate(struct(BeamCompass.Model.Snapshot), 2)
    assert {:ok, record} = Archive.put(snapshot, inputs, Path.join(root, "archives"))
    assert record["content_id"] == bundle["content_id"]
    assert File.exists?(record["path"])
  end

  test "tampered or unsupported bundles refuse rehydration without replacement", %{root: root} do
    {snapshot, inputs} = sample(:base)
    assert {:ok, bundle} = Archive.build(snapshot, inputs)
    assert {:error, :unsupported_archive_version} =
             Archive.validate(%{bundle | "schema_version" => 3})
    assert {:error, :archive_hash_mismatch} =
             Archive.validate(%{bundle | "snapshot_schema_version" => 2, "content_id" => String.duplicate("0", 64)})
    assert {:error, :invalid_archive_envelope} =
             Archive.rehydrate(Map.put(bundle, "observed_runtime", true))
    assert {:error, :invalid_archive_inputs} =
             Archive.build(snapshot, [%{"path" => "../escape.ex", "sha256" => hd(inputs)["sha256"]}])
    assert {:ok, ref} = Archive.put(snapshot, inputs, Path.join(root, "archives"))
    File.write!(ref["path"], "altered bytes")
    assert {:error, :archive_conflict} = Archive.put(snapshot, inputs, Path.join(root, "archives"))
    assert File.read!(ref["path"]) == "altered bytes"
  end

  test "fresh real source scans persist repeatably without evaluating target Mix", %{root: root} do
    code = File.read!(Path.join(@fixtures, "base.ex"))
    write_source(root, code, "transfer.ex")
    assert {:ok, scanned} = Export.scan(root, "fixture:archive-source")
    assert {:ok, first} = Archive.put(scanned.snapshot, scanned.inputs, Path.join(root, "archives"))
    assert {:ok, second} = Archive.put(scanned.snapshot, scanned.inputs, Path.join(root, "archives"))
    assert first == second
    assert {:ok, bundle} = Archive.get(Path.join(root, "archives"), first["content_id"])
    assert {:ok, snapshot} = Archive.rehydrate(bundle)
    assert snapshot["snapshot_id"] == scanned.snapshot["snapshot_id"]
  end

  test "canonical archive roundtrip holds deterministic content identity", %{root: root} do
    {snapshot, inputs} = sample(:base)
    assert {:ok, one} = Archive.put(snapshot, inputs, root)
    assert {:ok, two} = Archive.put(snapshot, inputs, root)
    assert one == two
    assert {:ok, bundle} = Archive.get(root, one["content_id"])
    assert {:ok, ^snapshot} = Archive.rehydrate(bundle)
    assert File.read!(one["path"]) == Json.encode(bundle) <> "\n"
  end

  test "wrong digest and malformed input identities fail without affecting prior data", %{root: root} do
    {snapshot, inputs} = sample(:base)
    assert {:ok, record} = Archive.put(snapshot, inputs, root)
    before = File.read!(record["path"])
    assert {:error, :invalid_archive_identity} = Archive.get(root, "../adversary")
    assert {:error, :archive_source_mismatch} =
             Archive.build(snapshot, [%{"path" => "lib/transfer.ex", "sha256" => String.duplicate("f", 64)}])
    assert {:error, _} = Archive.get(root, String.duplicate("f", 64))
    assert File.read!(record["path"]) == before
  end

  test "changed source invalidates transitive dependent evidence and analyses" do
    {snapshot, prior} = sample(:base)
    {_next_snapshot, next_inputs} = sample(:mutated)
    ev = hd(snapshot["evidence"])["id"]
    analyses = [
      %{"id" => "analysis:child", "depends_on" => ["analysis:root"]},
      %{"id" => "analysis:root", "depends_on" => [ev]}
    ]
    assert {:ok, plan} = Invalidation.plan(snapshot, prior, next_inputs, analyses)
    assert plan["changed_paths"] == ["lib/transfer.ex"]
    assert ev in plan["invalidated_evidence_ids"]
    assert plan["invalidated_analysis_ids"] == ["analysis:child", "analysis:root"]
    assert plan["fresh_source_reextraction_required"]
  end

  test "unrelated source change keeps independent registered analysis valid", %{root: root} do
    write_source(root, "defmodule Alpha do\n def work, do: IO.puts(:ok)\nend", "a.ex")
    write_source(root, "defmodule Beta do\n def work, do: :ok\nend", "b.ex")
    assert {:ok, source} = Export.scan(root, "fixture:p04-unrelated")
    evidence = Enum.find(source.snapshot["evidence"], &(&1["anchor"]["path"] == "lib/a.ex"))
    analyses = [%{"id" => "analysis:kept", "depends_on" => [evidence["id"]]}]
    updated = Enum.map(source.inputs, fn input ->
      if input["path"] == "lib/b.ex", do: %{input | "sha256" => String.duplicate("f", 64)}, else: input
    end)
    assert {:ok, plan} = Invalidation.plan(source.snapshot, source.inputs, updated, analyses)
    assert plan["invalidated_analysis_ids"] == []
    assert plan["retained_analysis_ids"] == ["analysis:kept"]
    assert plan["retained_reuse_status"] == "provisional_until_fresh_graph_is_verified"
    assert {:error, :invalid_analysis_dependencies} =
             Invalidation.plan(source.snapshot, source.inputs, updated,
               [%{"id" => "analysis:unknown", "depends_on" => ["phantom"]}])
  end

  test "source additions and changed parser settings conservatively invalidate derived graph" do
    {snapshot, before_inputs} = sample(:base)
    new_inputs = before_inputs ++ [%{"path" => "lib/new_source.ex", "sha256" => String.duplicate("c", 64)}]
    ev = hd(snapshot["evidence"])["id"]
    analyses = [%{"id" => "analysis:graph", "depends_on" => [ev]}]
    assert {:ok, plan} = Invalidation.plan(snapshot, before_inputs, new_inputs, analyses)
    assert plan["full_graph_invalidation"]
    assert plan["invalidated_analysis_ids"] == ["analysis:graph"]
    assert {:error, :invalid_invalidation_options} =
             Invalidation.plan(snapshot, before_inputs, before_inputs, [], config_digest: "wrong")
    assert {:error, :invalid_next_inputs} =
             Invalidation.plan(snapshot, before_inputs, Enum.reverse(new_inputs), [])
  end

  test "typed transition and effect diffs preserve exact before after evidence" do
    {before, _} = sample(:base)
    {after_snapshot, _} = sample(:mutated)
    assert {:ok, result} = ChangeSet.compare(before, after_snapshot)
    assert Enum.any?(result["changes"], &(&1["kind"] == "transition" and &1["operation"] == "modified"))
    assert Enum.any?(result["changes"], &(&1["kind"] == "effect_intent" and &1["operation"] == "removed"))
    assert result["affected_before_ids"] != []

    for item <- result["changes"], side <- ["before", "after"] do
      ref = item[side <> "_ref"]
      if ref do
        source = if side == "before", do: before, else: after_snapshot
        assert {:ok, obj} = Validator.validate_reference(source, ref)
        assert obj["evidence_ids"] == item[side <> "_evidence_ids"]
      end
    end
  end

  test "same claimed Git revision with different source bytes is rejected" do
    {before, _} = sample(:base)
    {later, _} = sample(:mutated)
    manifest = Map.put(later["manifest"], "source_revision", before["manifest"]["source_revision"])
    forged = later |> Map.put("manifest", manifest) |> rehash()
    assert :ok = Validator.validate(forged)
    assert {:error, :inconsistent_git_source_lineage} = ChangeSet.compare(before, forged)
  end

  test "typed failure-boundary and effect relation changes remain source-possible" do
    {before, _} = sample(:base)
    failed =
      before
      |> Map.update!("entities", fn objects ->
        Enum.sort_by(objects ++ [%{"id" => "failure:exit", "kind" => "failure_boundary",
          "label" => "possible supervisor restart", "semantic_key" => nil,
          "epistemic_status" => "proposed", "evidence_ids" => ["evidence:source"],
          "limitations" => ["source only"]}], & &1["id"])
      end)
      |> rehash()

    assert :ok = Validator.validate(failed)
    assert {:ok, changes} = ChangeSet.compare(before, failed)
    assert Enum.any?(changes["changes"], &(&1["kind"] == "failure_boundary" and &1["operation"] == "added"))
    assert Enum.all?(changes["changes"], &(&1["epistemic_status"] == "source_possible"))
  end

  test "ambiguous effect candidates never become confirmed performer matches" do
    {before, _} = sample(:base)
    {after_snapshot, _} = sample(:mutated)
    assert {:ok, result} = ChangeSet.compare(before, after_snapshot)
    refute Enum.any?(result["correspondence"],
             &(&1["resolution"] == "resolved_runtime_causality"))
    assert Enum.any?(after_snapshot["relations"],
             &(&1["kind"] == "performs_effect" and &1["resolution"] == "unresolved"))
    assert Enum.all?(result["changes"], &(&1["epistemic_status"] == "source_possible"))
    assert {:error, :cross_project_correspondence_refused} =
             ChangeSet.compare(before, %{after_snapshot | "project_id" => "unrelated"} |> rehash())
  end

  test "twenty distinct source questions require independently audited reviewer provenance" do
    {snapshot, _} = sample(:base)
    source = hd(snapshot["entities"])
    assert {:ok, ref} = Validator.reference(snapshot, "entity", source["id"])
    kinds = ~w(message_receivers state_writes effect_intents effect_sites intent_interpreters failure_restarts)
    subjects = ~w(function:void transition:reserved intent:void)

    questions = Enum.map(1..20, fn i ->
      id = "question:" <> String.pad_leading(Integer.to_string(i), 2, "0")
      kind = Enum.at(kinds, rem(i - 1, length(kinds)))
      subject = Enum.at(subjects, rem(div(i - 1, length(kinds)), length(subjects)))
      %{"id" => id, "question" => %{"id" => id, "kind" => kind, "subject" => subject},
        "expected_targets" => ["intent:void"], "unknown_expected" => i > 18,
        "source_reference" => ref}
    end)

    assert {:ok, audit} = Evaluation.corpus(snapshot, questions, [])
    assert audit["questions"] == 20
    assert audit["human_reviewed_count"] == 0
    assert audit["human_review_verification"] == "requires_independent_provenance_audit"
    assert {:error, :invalid_question_corpus} =
             Evaluation.corpus(snapshot, List.replace_at(questions, 19,
               Map.put(Enum.at(questions, 19), "question", Map.put(Enum.at(questions, 0)["question"], "id", "question:20"))
               |> Map.put("unknown_expected", false)), [])
  end

  test "unreviewed or self labeled questions cannot qualify as human review" do
    {snapshot, _} = sample(:base)
    assert {:error, :insufficient_or_malformed_corpus} = Evaluation.corpus(snapshot, [], [])
    ref = %{"provider" => "unrelated", "snapshot_schema_version" => 2,
            "project_id" => snapshot["project_id"], "snapshot_id" => snapshot["snapshot_id"],
            "object_kind" => "entity", "object_id" => "intent:void", "evidence_ids" => ["evidence:source"]}
    q = Enum.map(1..20, fn i ->
      id = "question:" <> String.pad_leading(Integer.to_string(i), 2, "0")
      %{"id" => id, "question" => %{"id" => id, "kind" => "effect_intents", "subject" => "intent:void"},
        "expected_targets" => [], "unknown_expected" => true, "source_reference" => ref}
    end)
    assert {:error, :invalid_question_corpus} = Evaluation.corpus(snapshot, q, [])
  end

  test "mutation measurements detect void intent and premature state release" do
    {before, _} = sample(:base)
    {after_snapshot, _} = sample(:mutated)
    assert {:ok, report} = Evaluation.measure(before, after_snapshot, independent_oracle())
    assert report["true_positive"] == 3
    assert report["false_positive"] == 0
    assert report["false_negative"] == 0
    assert report["unknown_count"] >= 1
    assert report["unknown_expectation_met"]
    assert report["elapsed_microseconds"] >= 0
  end

  test "unknown performer and false confidence are counted not reported as truth" do
    {before, _} = sample(:base)
    {after_snapshot, _} = sample(:mutated)
    wrong = update_in(independent_oracle(), ["expected_changes"], fn rows ->
      Enum.map(rows, &Map.put(&1, "after_label", "UNSUPPORTED-CLAIM")) |> Enum.sort()
    end)
    assert {:ok, metrics} = Evaluation.measure(before, after_snapshot, wrong)
    assert metrics["false_positive"] > 0
    assert metrics["false_negative"] > 0
    assert metrics["false_confidence"] == metrics["false_positive"]
    assert metrics["epistemic_status"] == "source_possible"
    refute Enum.any?(metrics["predicted"], &(&1["kind"] == "observed_effect"))
  end

  test "pinned lineage change set links affected IDs through exact references", %{root: root} do
    manifest = JSON.decode!(File.read!(Path.join(@fixtures, "manifest.json")))
    [base_rev, mutated_rev, shift_rev | _isolated] = manifest["revisions"]
    assert base_rev["git_sha"] != mutated_rev["git_sha"]
    assert mutated_rev["git_sha"] != shift_rev["git_sha"]
    for {rev, fixture_name} <- Enum.zip(manifest["revisions"], ["base.ex", "mutated.ex", "line_shifted.ex"]) do
      assert String.length(rev["git_sha"]) == 40
      assert rev["source_sha256"] == Provenance.sha256(File.read!(Path.join(@fixtures, fixture_name)))
    end

    {before, _} = sample(:base)
    {later, _} = sample(:mutated)
    assert {:ok, change} = ChangeSet.compare(before, later)
    assert change["before"]["source_revision"] == base_rev["git_sha"]
    assert change["after"]["source_revision"] == mutated_rev["git_sha"]
    assert change["affected_before_ids"] != []
    assert change["affected_after_ids"] != []
    assert change["change_set_id"] == Provenance.sha256(Json.encode(Map.delete(change, "change_set_id")))

    write_source(root, File.read!(Path.join(@fixtures, "base.ex")), "transfer.ex")
    assert {:error, :git_revision_unavailable} = Export.scan_git(root, "fixture:git-refusal")
  end

  test "Git source snapshot rejects a dirty source tree without executing target Mix", %{root: root} do
    write_source(root, File.read!(Path.join(@fixtures, "base.ex")), "transfer.ex")
    assert {_, 0} = System.cmd("git", ["init", "-q", root])
    assert {_, 0} = System.cmd("git", ["-C", root, "add", "lib/transfer.ex", "mix.exs"])
    assert {_, 0} = System.cmd("git", ["-C", root, "-c", "user.name=P04 fixture",
                                      "-c", "user.email=p04@beamcompass.invalid", "commit", "-qm", "fixture base"])
    assert {:ok, export} = Export.scan_git(root, "fixture:pinned")
    assert {:ok, head} = git_head(root)
    assert export.snapshot["manifest"]["source_revision"] == head
    assert :ok = Validator.validate(export.snapshot)
    write_source(root, File.read!(Path.join(@fixtures, "mutated.ex")), "transfer.ex")
    assert {:error, :uncommitted_source_bytes} = Export.scan_git(root, "fixture:pinned")
  end

  test "semantic collisions rename split merge and unmatched stay unresolved" do
    {before, _} = sample(:base)
    isolated = remove_descriptors(before)
    one = %{"id" => "intent:old", "kind" => "effect_intent", "label" => "semantic collision",
            "semantic_key" => "same-key", "epistemic_status" => "proposed",
            "evidence_ids" => ["evidence:source"], "limitations" => ["source only"]}
    first = isolated |> Map.put("entities", Enum.sort_by([one], & &1["id"])) |> rehash()
    other = %{one | "id" => "intent:new"}
    second = isolated |> Map.put("entities", [other]) |> rehash()
    assert {:ok, renamed} = ChangeSet.compare(first, second)
    assert Enum.any?(renamed["correspondence"], &(&1["outcome"] == "rename_candidate" and &1["resolution"] == "uncertain"))
    refute Enum.any?(renamed["correspondence"], &(&1["outcome"] == "matched"))
    split = isolated |> Map.put("entities", Enum.sort_by([other, %{other | "id" => "intent:third"}], & &1["id"])) |> rehash()
    assert {:ok, split_result} = ChangeSet.compare(first, split)
    assert Enum.any?(split_result["correspondence"], &(&1["outcome"] == "split_candidate" and &1["resolution"] == "uncertain"))
    assert {:ok, merge_result} = ChangeSet.compare(split, first)
    assert Enum.any?(merge_result["correspondence"], &(&1["outcome"] == "merge_candidate" and &1["resolution"] == "uncertain"))
  end


  test "isolated mutation releases capacity without erasing the returned effect intent" do
    {prior, _} = sample(:base)
    {after_snapshot, _} = sample(:early_release)
    assert {:ok, changes} = ChangeSet.compare(prior, after_snapshot)
    assert Enum.count(changes["changes"], & &1["semantic_change"]) == 1
    assert Enum.any?(changes["changes"], &(&1["kind"] == "transition" and &1["operation"] == "modified"))
    refute Enum.any?(changes["changes"], &(&1["kind"] == "effect_intent"))
  end

  test "isolated mutation removes returned intent without changing the state transition" do
    {prior, _} = sample(:base)
    {after_snapshot, _} = sample(:intent_removed)
    assert {:ok, changes} = ChangeSet.compare(prior, after_snapshot)
    assert Enum.count(changes["changes"], & &1["semantic_change"]) == 2
    assert Enum.any?(changes["changes"], &(&1["kind"] == "effect_intent" and &1["operation"] == "removed"))
    refute Enum.any?(changes["changes"], &(&1["kind"] == "transition"))
    assert Enum.any?(after_snapshot["relations"], &(&1["kind"] == "performs_effect" and &1["resolution"] == "unresolved"))
  end

  test "same pinned Git revision cannot silently claim different source inputs" do
    {prior, _} = sample(:base)
    {later, _} = sample(:mutated)
    forged = later
      |> put_in(["manifest", "source_revision"], prior["manifest"]["source_revision"])
      |> rehash()
    assert :ok = Validator.validate(forged)
    assert {:error, :inconsistent_git_source_lineage} = ChangeSet.compare(prior, forged)
  end

  test "failure boundary changes carry exact source only before after references" do
    {base, _} = sample(:base)
    failure = %{"id" => "failure:local", "kind" => "failure_boundary", "label" => "raise local",
                "semantic_key" => nil, "epistemic_status" => "proposed",
                "evidence_ids" => ["evidence:source"], "limitations" => ["source only"]}
    before = base
      |> Map.put("entities", Enum.sort_by([failure | base["entities"]], & &1["id"]))
      |> rehash()
    after_snapshot = before
      |> Map.put("entities", Enum.map(before["entities"], fn
        %{"id" => "failure:local"} = row -> %{row | "label" => "throw local"}
        row -> row
      end))
      |> rehash()
    assert :ok = Validator.validate(before)
    assert :ok = Validator.validate(after_snapshot)
    assert {:ok, diff} = ChangeSet.compare(before, after_snapshot)
    assert [change] = Enum.filter(diff["changes"], &(&1["kind"] == "failure_boundary"))
    assert change["operation"] == "modified"
    assert {:ok, _} = Validator.validate_reference(before, change["before_ref"])
    assert {:ok, _} = Validator.validate_reference(after_snapshot, change["after_ref"])
    assert change["epistemic_status"] == "source_possible"
  end

  test "separate pinned source mutations detect transition and returned intent independently", %{root: root} do
    write_source(root, File.read!(Path.join(@fixtures, "base.ex")), "transfer.ex")
    assert {:ok, baseline} = Export.scan(root, "fixture:isolated")
    write_source(root, File.read!(Path.join(@fixtures, "early_release.ex")), "transfer.ex")
    assert {:ok, release} = Export.scan(root, "fixture:isolated")
    assert {:ok, release_changes} = ChangeSet.compare(baseline.snapshot, release.snapshot)
    assert Enum.any?(release_changes["changes"],
             &(&1["kind"] == "transition" and &1["semantic_change"]))
    refute Enum.any?(release_changes["changes"],
             &(&1["kind"] == "effect_intent" and &1["operation"] == "removed"))

    write_source(root, File.read!(Path.join(@fixtures, "intent_removed.ex")), "transfer.ex")
    assert {:ok, without_intent} = Export.scan(root, "fixture:isolated")
    assert {:ok, intent_changes} = ChangeSet.compare(baseline.snapshot, without_intent.snapshot)
    assert Enum.any?(intent_changes["changes"],
             &(&1["kind"] == "effect_intent" and &1["operation"] == "removed"))
    assert Enum.all?(intent_changes["changes"],
             &(&1["epistemic_status"] == "source_possible"))
  end

  test "TEST-P04-01 line shift changes anchors without fabricated semantic diff" do
    {before, _} = sample(:mutated)
    {later, _} = sample(:shifted)
    assert before["snapshot_id"] != later["snapshot_id"]
    assert before["manifest"]["source_digest"] != later["manifest"]["source_digest"]
    assert {:ok, change} = ChangeSet.compare(before, later)
    refute Enum.any?(change["changes"], & &1["semantic_change"])
  end

  test "actual source witness distinguishes Map argument mutation from pure line shifts", %{root: root} do
    code = """
    defmodule BeamCompass.P04StateMutation do
      def step(state), do: Map.put(state, :status, :pending)
    end
    """
    write_source(root, code, "case.ex")
    assert {:ok, baseline} = Export.scan(root, "fixture:state-diff")
    write_source(root, "\n\n" <> code, "case.ex")
    assert {:ok, shifted} = Export.scan(root, "fixture:state-diff")
    assert {:ok, shift_diff} = ChangeSet.compare(baseline.snapshot, shifted.snapshot)
    refute Enum.any?(shift_diff["changes"], & &1["semantic_change"])

    write_source(root, String.replace(code, ":pending", ":released"), "case.ex")
    assert {:ok, changed} = Export.scan(root, "fixture:state-diff")
    assert {:ok, changes} = ChangeSet.compare(baseline.snapshot, changed.snapshot)
    assert Enum.any?(changes["changes"],
             &(&1["kind"] == "transition" and &1["operation"] == "modified" and
                 &1["semantic_change"]))
    assert Enum.all?(changes["changes"], &(&1["epistemic_status"] == "source_possible"))
  end

  test "TEST-P04-02 the source-only exporter detects both fixture mutation classes", %{root: root} do
    write_source(root, File.read!(Path.join(@fixtures, "base.ex")), "transfer.ex")
    assert {:ok, before} = Export.scan(root, "fixture:raw-source")
    write_source(root, File.read!(Path.join(@fixtures, "mutated.ex")), "transfer.ex")
    assert {:ok, after_export} = Export.scan(root, "fixture:raw-source")
    assert {:ok, changes} = ChangeSet.compare(before.snapshot, after_export.snapshot)
    assert changes["before"]["source_digest"] != changes["after"]["source_digest"]
    assert Enum.any?(changes["changes"], &(&1["semantic_change"] and &1["kind"] in ~w(transition effect_intent)))
    assert Enum.all?(changes["changes"], &(&1["epistemic_status"] == "source_possible"))
  end

  defp git_head(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "HEAD"]) do
      {sha, 0} -> {:ok, String.trim(sha)}
      _ -> {:error, :git_revision_unavailable}
    end
  end

  defp sample(which) do
    versions = JSON.decode!(File.read!(Path.join(@fixtures, "manifest.json")))["revisions"]
    index = %{base: 0, mutated: 1, shifted: 2, early_release: 3, intent_removed: 4}[which]
    rev = Enum.at(versions, index)
    sha = Provenance.sha256(File.read!(Path.join(@fixtures, Map.get(@cases, which, Atom.to_string(which) <> ".ex"))))
    input = %{"path" => "lib/transfer.ex", "sha256" => sha}
    source_digest = Provenance.sha256(Json.encode([input]))
    anchor = %{"path" => input["path"], "source_sha256" => sha,
               "start_line" => if(which == :shifted, do: 5, else: 1), "start_column" => 1,
               "end_line" => nil, "end_column" => nil}
    evidence = [%{"id" => "evidence:source", "provider_id" => "provider:ast", "mode" => "source",
                  "anchor" => anchor, "basis" => "source syntax only", "input_evidence_ids" => []}]
    transition = %{"id" => "transition:reserved", "kind" => "transition",
                   "label" => if(which in [:base, :intent_removed], do: "capacity reserved after void", else: "capacity released on void"),
                   "semantic_key" => "fixture:capacity:void", "epistemic_status" => "proposed",
                   "evidence_ids" => ["evidence:source"], "limitations" => ["no runtime state proof"]}
    function = %{"id" => "function:void", "kind" => "function", "label" => "BeamCompass.P04SourceCase.void/2",
                 "semantic_key" => nil, "epistemic_status" => "sourced", "evidence_ids" => ["evidence:source"],
                 "limitations" => []}
    intent = %{"id" => "intent:void", "kind" => "effect_intent", "label" => "void intent returned",
               "semantic_key" => nil, "epistemic_status" => "proposed", "evidence_ids" => ["evidence:source"],
               "limitations" => ["source intent not execution"]}
    entities = if which in [:base, :early_release], do: [function, intent, transition], else: [function, transition]
    edge = %{"id" => "relation:performer", "kind" => "performs_effect",
             "source_id" => function["id"], "target_id" => nil, "resolution" => "unresolved",
             "epistemic_status" => "unresolved", "evidence_ids" => ["evidence:source"],
             "rationale" => "dynamic apply remains unknown"}
    described = %{"id" => "relation:described", "kind" => "describes_effect",
                  "source_id" => function["id"], "target_id" => intent["id"], "resolution" => "resolved",
                  "epistemic_status" => "sourced", "evidence_ids" => ["evidence:source"],
                  "rationale" => "static returned tuple intent"}
    relations = if which in [:base, :early_release], do: [described, edge], else: [edge]
    body = %{"format" => "beamcompass.snapshot", "schema_version" => 2,
             "project_id" => "fixture:beamcompass-p04", "manifest" => %{
               "source_revision" => rev["git_sha"], "source_digest" => source_digest,
               "config_digest" => Provenance.sha256("fixture-config"),
               "toolchain" => %{"elixir" => "fixture", "otp" => "fixture"},
               "providers" => [%{"id" => "provider:ast", "name" => "p04-independent-fixture",
                                "version" => "1", "mode" => "source", "trust_context" => "inert bytes"}]},
             "entities" => Enum.sort_by(entities, & &1["id"]),
             "relations" => Enum.sort_by(relations, & &1["id"]),
             "evidence" => evidence, "issues" => [], "limitations" => ["fixture graph; no observed runtime causality"]}
    {rehash(body), [input]}
  end

  defp independent_oracle do
    expected = [
      %{"kind" => "transition", "operation" => "modified", "before_label" => "capacity reserved after void",
        "after_label" => "capacity released on void", "before_path" => "lib/transfer.ex", "after_path" => "lib/transfer.ex"},
      %{"kind" => "effect_intent", "operation" => "removed", "before_label" => "void intent returned",
        "after_label" => nil, "before_path" => "lib/transfer.ex", "after_path" => nil},
      %{"kind" => "effect_intent", "operation" => "removed",
        "before_label" => "describes_effect:function:void->intent:void",
        "after_label" => nil, "before_path" => "lib/transfer.ex", "after_path" => nil}
    ]
    %{"case_id" => "fixture:capacity-and-void", "expected_changes" => Enum.sort(expected),
      "expected_unknown_min" => 1}
  end

  defp remove_descriptors(snapshot) do
    snapshot
    |> Map.put("entities", [])
    |> Map.put("relations", [])
    |> rehash()
  end

  defp rehash(snapshot) do
    Map.put(snapshot, "snapshot_id", Validator.fingerprint(snapshot))
  end

  defp write_source(root, code, name) do
    path = Path.join([root, "lib", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, code)
  end
end
