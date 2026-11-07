defmodule BeamCompass.SourceProjectionTest do
  use ExUnit.Case, async: true

  alias BeamCompass.Behavior.Validator
  alias BeamCompass.Json
  alias BeamCompass.Model.Codec

  setup do
    root =
      Path.join(System.tmp_dir!(), "beamcompass_projection_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "fixture message edges remain possible, with unresolved sends", _context do
    snapshot = sample()
    entities = Map.new(snapshot["entities"], &{&1["id"], &1})

    candidates = Enum.filter(snapshot["relations"], &(&1["kind"] == "may_deliver_to"))
    assert length(candidates) >= 2
    assert Enum.all?(candidates, &(&1["resolution"] == "possible"))
    assert Enum.all?(candidates, &(&1["epistemic_status"] == "proposed"))
    assert Enum.all?(candidates, &(entities[&1["target_id"]]["kind"] == "trigger"))

    assert Enum.any?(candidates, fn r ->
             String.contains?(entities[r["source_id"]]["label"], "authorize/1")
           end)

    assert Enum.any?(candidates, fn r ->
             String.contains?(entities[r["source_id"]]["label"], "handle_call/3")
           end)

    assert Enum.any?(snapshot["relations"], fn r ->
             r["kind"] == "sends" and r["resolution"] == "unresolved" and
               is_nil(r["target_id"])
           end)

    for relation <- candidates do
      assert {:ok, exact} = BeamCompass.source_reference(snapshot, "relation", relation["id"])
      assert {:ok, ^relation} = BeamCompass.resolve_source_reference(snapshot, exact)
      assert Enum.all?(exact["evidence_ids"], &String.starts_with?(&1, "evidence:"))
    end
  end

  test "no receiver, alias, tag or wildcard guessing creates a message recipient", %{root: root} do
    write_project(root, """
    defmodule Uncertain do
      use GenServer
      def notify(destination), do: send(destination, :tick)
      def call_unknown(destination), do: GenServer.cast(destination, :tick)
      def emit, do: send(self(), :unmatched)
      def handle_info(:tick, state), do: {:noreply, state}
      def handle_cast(:tick, state), do: {:noreply, state}
    end
    """)

    assert {:ok, snapshot} = BeamCompass.export_source(root, project_id: "test:uncertain")
    refute Enum.any?(snapshot["relations"], &(&1["kind"] == "may_deliver_to"))

    assert Enum.any?(
             snapshot["relations"],
             &(&1["kind"] == "sends" and
                 &1["resolution"] == "unresolved")
           )
  end

  test "unique syntactic executor tag is a possible candidate, never a performer claim" do
    snapshot = sample()
    indexed = Map.new(snapshot["entities"], &{&1["id"], &1})

    possible =
      Enum.filter(snapshot["relations"], fn relation ->
        relation["kind"] == "causally_related" and
          indexed[relation["source_id"]]["kind"] == "effect_intent"
      end)

    assert possible != []
    assert Enum.all?(possible, &(&1["resolution"] == "possible"))
    assert Enum.all?(possible, &(&1["epistemic_status"] == "proposed"))
    assert Enum.all?(possible, &(indexed[&1["target_id"]]["kind"] == "function"))

    assert Enum.any?(
             snapshot["relations"],
             &(&1["kind"] == "performs_effect" and
                 &1["resolution"] == "unresolved")
           )

    assert :ok = Validator.validate(snapshot)
  end

  test "ambiguous executor tags never imply an interpreter selection", %{root: root} do
    write_project(root, """
    defmodule Uncertain do
      def reducer, do: {:dispatch, :notice}
      def execute({:dispatch, :one}), do: IO.puts("first")
      def execute({:dispatch, :two}), do: IO.puts("second")
    end
    """)

    assert {:ok, snapshot} = BeamCompass.export_source(root, project_id: "test:tags")
    indexed = Map.new(snapshot["entities"], &{&1["id"], &1})

    refute Enum.any?(snapshot["relations"], fn r ->
             r["kind"] == "causally_related" and
               indexed[r["source_id"]]["kind"] == "effect_intent"
           end)

    assert Enum.any?(
             snapshot["relations"],
             &(&1["kind"] == "performs_effect" and
                 &1["resolution"] == "unresolved")
           )
  end

  test "bounded recursive capsule paths expand every included source reference", %{root: root} do
    write_project(root, """
    defmodule Recur do
      use GenServer
      def handle_info(:tick, state) do
        send(self(), :tick)
        {:noreply, Map.put(state, :count, 1)}
      end
    end
    """)

    assert {:ok, snapshot} = BeamCompass.export_source(root, project_id: "test:cycle")
    assert {:ok, capsules} = BeamCompass.capsules_source(snapshot)
    assert length(capsules) == 1
    [capsule] = capsules
    refute capsule["truncated"]
    assert capsule["cut_relation_ids"] == []
    assert capsule["ordering"] == "not_observed_or_runtime_proven"

    assert Enum.any?(capsule["relation_ids"], fn id ->
             Enum.any?(
               snapshot["relations"],
               &(&1["id"] == id and
                   &1["kind"] == "may_deliver_to")
             )
           end)

    assert {:ok, req} = BeamCompass.projection_request(snapshot, lens: :behavior, budget: 20)
    assert {:ok, result} = BeamCompass.project_source(snapshot, req)
    assert length(result["capsules"]) == 1

    for ref <- hd(result["capsules"])["members"] ++ hd(result["capsules"])["relations"] do
      assert {:ok, _} = BeamCompass.resolve_source_reference(snapshot, ref)
    end

    assert Json.encode(result) == Json.encode(elem(BeamCompass.project_source(snapshot, req), 1))
  end

  test "budget cannot hide requested async/effect/unknown boundaries", _context do
    snapshot = sample()
    effect = Enum.find(snapshot["entities"], &(&1["kind"] == "effect"))
    assert {:ok, ref} = BeamCompass.source_reference(snapshot, "entity", effect["id"])

    assert {:ok, request} =
             BeamCompass.projection_request(snapshot,
               lens: :effects,
               budget: 1,
               preserve: [ref],
               boundaries: [:async, :effect, :unknown]
             )

    assert {:ok, result} = BeamCompass.project_source(snapshot, request)
    assert length(result["visible"]) <= 1
    refute ref in result["visible"]

    assert Enum.any?(result["receipt"]["witnesses"], fn witness ->
             witness["requested"] == ref and witness["status"] == "budget_lost"
           end)

    assert result["receipt"]["status"] == "unsatisfied"
    assert result["receipt"]["completeness"] == "incomplete_preservation"
    assert result["receipt"]["unsatisfied"] != []

    assert Enum.all?(result["receipt"]["unsatisfied"], fn missing ->
             Enum.any?(result["receipt"]["witnesses"], fn witness ->
               witness["requested"] == missing and witness["status"] != "preserved"
             end)
           end)

    assert result["unknown"] != []

    assert Enum.all?(result["unknown"], fn unknown ->
             assert unknown["reason"] == "unresolved_source_relation"
             {:ok, item} = BeamCompass.resolve_source_reference(snapshot, unknown["reference"])
             item["resolution"] == "unresolved"
           end)

    for ref <- result["visible"] do
      assert {:ok, _} = BeamCompass.resolve_source_reference(snapshot, ref)
    end
  end

  test "missing failure evidence is unsatisfied, never interpreted as absence" do
    snapshot = sample()

    assert {:ok, request} =
             BeamCompass.projection_request(snapshot,
               lens: :failure,
               budget: 30,
               boundaries: [:failure]
             )

    assert {:ok, result} = BeamCompass.project_source(snapshot, request)
    assert result["receipt"]["missing_boundaries"] == ["failure"]
    assert result["receipt"]["status"] == "unsatisfied"
    assert result["receipt"]["completeness"] == "incomplete_preservation"
  end

  test "closed request/version/source reference/refusal cannot be bypassed" do
    snapshot = sample()
    assert {:ok, request} = BeamCompass.projection_request(snapshot)

    for {field, value, expected} <- [
          {"schema_version", 2, :unsupported_projection_version},
          {"snapshot_schema_version", 3, :unsupported_snapshot_version},
          {"lens", "unsupported_lens", :unsupported_projection_lens},
          {"budget", 0, :invalid_projection_budget},
          {"budget", 999, :invalid_projection_budget},
          {"project_id", "wrong", :wrong_projection_namespace},
          {"snapshot_id", String.duplicate("a", 64), :wrong_projection_namespace}
        ] do
      assert {:error, ^expected} =
               BeamCompass.project_source(snapshot, Map.put(request, field, value))
    end

    assert {:error, :invalid_projection_request} =
             BeamCompass.project_source(snapshot, Map.put(request, "approval", "yes"))

    assert {:error, :unsupported_preservation_boundary} =
             BeamCompass.projection_request(snapshot, boundaries: [:proof_result])

    assert {:error, :invalid_projection_options} =
             BeamCompass.projection_request(snapshot, unsupported_option: :yes)

    assert {:error, :invalid_projection_preserve} =
             BeamCompass.projection_request(snapshot, preserve: ["not_a_reference"])

    assert {:error, :invalid_projection_preserve} =
             BeamCompass.project_source(
               snapshot,
               put_in(request, ["preserve", "references"], [false])
             )

    assert {:error, :unsupported_projection_reference_kind} =
             BeamCompass.projection_request(snapshot,
               focus:
                 elem(
                   BeamCompass.source_reference(
                     snapshot,
                     "evidence",
                     hd(snapshot["evidence"])["id"]
                   ),
                   1
                 )
             )

    bad = put_in(snapshot, ["manifest", "providers", Access.at(0), "mode"], "observed")
    assert {:error, _} = BeamCompass.project_source(bad, request)
    assert {:error, :invalid_envelope} = BeamCompass.project_source(%{}, request)
  end

  test "mutation fidelity: changed transition evidence and removed executor effect remain distinct",
       %{root: root} do
    source = """
    defmodule Mutation do
      def step(state), do: {Map.put(state, :status, :pending), [{:dispatch, :notify}]}
      def execute({:dispatch, _payload}), do: IO.puts("a")
    end
    """

    write_project(root, source)
    assert {:ok, baseline} = BeamCompass.export_source(root, project_id: "test:mutation")
    first_transition = Enum.find(baseline["entities"], &(&1["kind"] == "transition"))
    assert first_transition

    write_project(root, String.replace(source, ":pending", ":released"))
    assert {:ok, changed} = BeamCompass.export_source(root, project_id: "test:mutation")
    changed_transition = Enum.find(changed["entities"], &(&1["kind"] == "transition"))
    assert changed_transition["id"] == first_transition["id"]
    refute changed_transition["evidence_ids"] == first_transition["evidence_ids"]
    refute changed["manifest"]["source_digest"] == baseline["manifest"]["source_digest"]

    write_project(root, String.replace(source, "IO.puts(\"a\")", ":ok"))
    assert {:ok, no_io} = BeamCompass.export_source(root, project_id: "test:mutation")
    assert io_performer?(baseline)
    refute io_performer?(no_io)

    assert Enum.any?(
             no_io["relations"],
             &(&1["kind"] == "performs_effect" and
                 &1["resolution"] == "unresolved")
           )

    assert Enum.any?(no_io["entities"], &(&1["kind"] == "effect_intent"))
  end

  test "small question baseline returns supported data or explicit unknown; v1 unchanged" do
    root = Path.expand("../../../fixtures/ledger_sample", __DIR__)
    assert {:ok, v1} = BeamCompass.scan(root)
    bytes = Codec.encode(v1)
    snapshot = sample()
    assert {:ok, v1_loaded} = Codec.decode(bytes)
    assert Codec.encode(v1_loaded) == bytes
    assert {:ok, _} = BeamCompass.project(v1, lens: :effects, budget: 2)

    # Typed question answers use matched endpoints and source uncertainty,
    # rather than the presence of an unrelated relation KIND in the graph.
    query = %{
      "id" => "authorize_route",
      "kind" => "message_receivers",
      "subject" => "LedgerSample.Server.authorize/1"
    }

    assert {:ok, answer} = BeamCompass.answer_source(snapshot, query)
    assert answer["status"] == "source_possible"
    assert Enum.any?(answer["answers"], &String.contains?(&1["target_label"], "handle_call/3"))
    assert answer["unknown"] != []
    assert :ok = Validator.validate(snapshot)
  end

  defp sample do
    root = Path.expand("../../../fixtures/ledger_sample", __DIR__)
    {:ok, snapshot} = BeamCompass.export_source(root, project_id: "fixture:ledger")
    snapshot
  end

  defp write_project(root, code) do
    File.write!(Path.join(root, "mix.exs"), "defmodule SourceFixture.MixProject do\nend\n")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/example.ex"), code)
  end

  defp io_performer?(snapshot) do
    indexed = Map.new(snapshot["entities"], &{&1["id"], &1})

    Enum.any?(snapshot["relations"], fn relation ->
      relation["kind"] == "performs_effect" and relation["resolution"] == "resolved" and
        String.contains?(indexed[relation["target_id"]]["label"], "IO.puts")
    end)
  end
end
