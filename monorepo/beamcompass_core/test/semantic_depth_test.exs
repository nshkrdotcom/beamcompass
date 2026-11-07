defmodule BeamCompass.SemanticDepthTest do
  use ExUnit.Case, async: true

  alias BeamCompass.Behavior.Validator
  alias BeamCompass.Json

  setup do
    root =
      Path.join(System.tmp_dir!(), "beamcompass_p03_depth_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "literal cross-process GenServer route is possible with unresolved transport", %{
    root: root
  } do
    write_source(root, """
    defmodule Postal.Server do
      use GenServer
      def handle_cast({:ping, data}, state), do: {:noreply, state}
    end
    defmodule Postal.Client do
      def dispatch(value), do: GenServer.cast(Postal.Server, {:ping, value})
    end
    """)

    snapshot = export(root)
    candidates = Enum.filter(snapshot["relations"], &(&1["kind"] == "may_deliver_to"))
    assert length(candidates) == 1
    [candidate] = candidates
    assert candidate["resolution"] == "possible"
    assert candidate["epistemic_status"] == "proposed"
    assert source_label(snapshot, candidate) =~ "Postal.Client.dispatch/1"
    assert target_label(snapshot, candidate) =~ "Postal.Server.handle_cast/2"

    assert Enum.any?(
             snapshot["relations"],
             &(&1["kind"] == "sends" and
                 &1["resolution"] == "unresolved")
           )

    assert :ok = Validator.validate(snapshot)
  end

  test "wrong tag, unknown PID and ambiguous callback cannot be asserted", %{root: root} do
    write_source(root, """
    defmodule Postal.Server do
      use GenServer
      def handle_cast({:other, _data}, state), do: {:noreply, state}
      def handle_cast({:ping, _data}, state), do: {:noreply, state}
      def handle_cast({:ping, :fixed}, state), do: {:noreply, state}
    end
    defmodule Postal.Client do
      def deliver(value), do: GenServer.cast(Postal.Server, {:ping, value})
      def unknown(pid), do: GenServer.cast(pid, {:other, 1})
    end
    """)

    snapshot = export(root)
    refute Enum.any?(snapshot["relations"], &(&1["kind"] == "may_deliver_to"))

    assert Enum.count(
             snapshot["relations"],
             &(&1["kind"] == "sends" and
                 &1["resolution"] == "unresolved")
           ) >= 2
  end

  test "candidate reducer-to-executor chain requires effect-variable transfer", %{root: root} do
    source = File.read!(fixture_file("server.ex"))
    root_ledger = File.read!(fixture_file("ledger.ex"))
    executor = File.read!(fixture_file("effect_executor.ex"))
    File.write!(Path.join(root, "mix.exs"), "# inert target project\n")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/server.ex"), source)
    File.write!(Path.join(root, "lib/ledger.ex"), root_ledger)
    File.write!(Path.join(root, "lib/executor.ex"), executor)
    baseline = export(root)

    assert Enum.any?(flow_edges(baseline), fn edge ->
             source_label(baseline, edge) =~ "LedgerSample.Ledger.step/2" and
               target_label(baseline, edge) =~ "LedgerSample.EffectExecutor.execute/1"
           end)

    # Wrong variable: send updated state rather than emitted effects. A tag
    # match alone is not proof of a reducer/interpreter handoff.
    File.write!(
      Path.join(root, "lib/server.ex"),
      String.replace(source, "{:run_effects, effects}", "{:run_effects, updated}", global: false)
    )

    broken = export(root)
    assert flow_edges(broken) == []

    assert Enum.any?(
             broken["relations"],
             &(&1["kind"] == "performs_effect" and
                 &1["resolution"] == "unresolved")
           )
  end

  test "static supervisor membership and explicit failure/decision sites remain candidates", %{
    root: root
  } do
    write_source(root, """
    defmodule Child do
      use GenServer
      def handle_info(:tick, state) do
        if state == :bad, do: raise("boom")
        {:noreply, state}
      end
    end
    defmodule Parent do
      use Supervisor
      def init(_opts) do
        children = [Child]
        Supervisor.init(children, strategy: :one_for_one)
      end
    end
    """)

    snapshot = export(root)
    kinds = Enum.map(snapshot["entities"], & &1["kind"])
    assert "decision" in kinds
    assert "failure_boundary" in kinds

    assert Enum.any?(
             snapshot["relations"],
             &(&1["kind"] == "supervises" and
                 &1["resolution"] == "possible")
           )

    assert Enum.any?(
             snapshot["relations"],
             &(&1["kind"] == "may_restart" and
                 &1["resolution"] == "possible")
           )

    assert :ok = Validator.validate(snapshot)
  end

  test "critical effect preservation requires complete endpoints and a path witness" do
    snapshot = sample()
    effect = Enum.find(snapshot["entities"], &(&1["kind"] == "effect"))
    {:ok, ref} = BeamCompass.source_reference(snapshot, "entity", effect["id"])

    {:ok, full_request} =
      BeamCompass.projection_request(snapshot, lens: :behavior, budget: 256, preserve: [ref])

    {:ok, full} = BeamCompass.project_source(snapshot, full_request)
    witness = Enum.find(full["receipt"]["witnesses"], &(&1["requested"] == ref))
    assert witness["path_supported"]
    assert witness["path"] != []
    assert witness["status"] == "preserved"
    assert Enum.all?(witness["dependency_refs"], &(&1 in full["visible"]))
    assert full["receipt"]["status"] == "satisfied"

    {:ok, tiny_request} =
      BeamCompass.projection_request(snapshot, lens: :effects, budget: 1, preserve: [ref])

    {:ok, tiny} = BeamCompass.project_source(snapshot, tiny_request)
    tiny_witness = Enum.find(tiny["receipt"]["witnesses"], &(&1["requested"] == ref))
    assert tiny_witness["status"] == "budget_lost"
    assert tiny["receipt"]["status"] == "unsatisfied"
    assert ref in tiny["receipt"]["unsatisfied"]

    assert Json.encode(tiny) ==
             Json.encode(elem(BeamCompass.project_source(snapshot, tiny_request), 1))
  end

  test "question oracle scores precise endpoints, unknowns and false positives" do
    snapshot = sample()
    oracles = fixture_oracles()
    assert {:ok, report} = BeamCompass.benchmark_source(snapshot, oracles)
    assert report["metrics"]["questions"] == length(oracles)
    assert report["metrics"]["passed"] == length(oracles)
    assert report["metrics"]["false_positive"] == 0
    assert report["metrics"]["false_negative"] == 0
    assert report["metrics"]["unknown_expectation_mismatches"] == 0
    assert report["metrics"]["precision"] == 1.0
    assert report["metrics"]["recall"] == 1.0
    assert report["metrics"]["unknown_rate"] > 0.0
    assert :ok = Validator.validate(snapshot)

    altered =
      List.update_at(oracles, 0, fn oracle ->
        Map.put(oracle, "expected_targets", ["Nonexistent.callback/1"])
      end)

    assert {:ok, falsified} = BeamCompass.benchmark_source(snapshot, altered)
    assert falsified["metrics"]["false_positive"] > 0
    assert falsified["metrics"]["false_negative"] > 0
    assert falsified["metrics"]["passed"] < length(oracles)
  end

  test "effect removal is detected by answers, not only by relation-kind counts", %{root: root} do
    original = """
    defmodule Probe do
      def execute({:dispatch, _x}), do: IO.puts("sent")
    end
    """

    write_source(root, original)
    before = export(root)
    question = %{"id" => "probe", "kind" => "effect_sites", "subject" => "Probe.execute/1"}
    assert {:ok, supported} = BeamCompass.answer_source(before, question)
    assert supported["status"] == "source_syntactic"
    assert Enum.any?(supported["answers"], &String.contains?(&1["target_label"], "IO.puts/1"))

    write_source(root, String.replace(original, "IO.puts(\"sent\")", ":ok"))
    after_snapshot = export(root)
    assert {:ok, changed} = BeamCompass.answer_source(after_snapshot, question)
    assert changed["status"] == "unknown"
    assert changed["answers"] == []
    assert before["manifest"]["source_digest"] != after_snapshot["manifest"]["source_digest"]
  end

  test "line-only moves preserve source question targets and stable fact IDs", %{root: root} do
    source = """
    defmodule Stable do
      def execute(value), do: IO.puts(value)
    end
    """

    write_source(root, source)
    first = export(root)
    question = %{"id" => "stable", "kind" => "effect_sites", "subject" => "Stable.execute/1"}
    {:ok, one} = BeamCompass.answer_source(first, question)

    write_source(root, "\n\n" <> source)
    second = export(root)
    {:ok, two} = BeamCompass.answer_source(second, question)

    assert Enum.map(one["answers"], & &1["target_label"]) ==
             Enum.map(two["answers"], & &1["target_label"])

    assert Enum.map(one["answers"], & &1["target"]["object_id"]) ==
             Enum.map(two["answers"], & &1["target"]["object_id"])

    refute first["snapshot_id"] == second["snapshot_id"]
  end

  defp flow_edges(snapshot) do
    index = Map.new(snapshot["entities"], &{&1["id"], &1})

    Enum.filter(snapshot["relations"], fn r ->
      r["kind"] == "causally_related" and
        index[r["source_id"]]["kind"] == "effect_intent"
    end)
  end

  defp sample do
    root = Path.expand("../../../fixtures/ledger_sample", __DIR__)
    {:ok, snapshot} = BeamCompass.export_source(root, project_id: "fixture:ledger")
    snapshot
  end

  defp fixture_file(file) do
    Path.expand("../../../fixtures/ledger_sample/lib/ledger_sample/#{file}", __DIR__)
  end

  defp export(root) do
    {:ok, snapshot} = BeamCompass.export_source(root, project_id: "test:semantic-depth")
    snapshot
  end

  defp write_source(root, source) do
    File.write!(Path.join(root, "mix.exs"), "# inert Mix fixture\n")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/example.ex"), source)
  end

  defp source_label(snapshot, relation) do
    snapshot["entities"] |> Enum.find(&(&1["id"] == relation["source_id"])) |> Map.fetch!("label")
  end

  defp target_label(snapshot, relation) do
    snapshot["entities"] |> Enum.find(&(&1["id"] == relation["target_id"])) |> Map.fetch!("label")
  end

  defp fixture_oracles do
    [
      oracle(
        "q1",
        "message_receivers",
        "LedgerSample.Server.authorize/1",
        ["LedgerSample.Server.handle_call/3"],
        true
      ),
      oracle(
        "q2",
        "state_writes",
        "LedgerSample.Ledger.step/2",
        ["LedgerSample.Ledger.step/2 · Map.put/3"],
        true
      ),
      oracle(
        "q3",
        "message_receivers",
        "LedgerSample.Server.handle_call/3",
        ["LedgerSample.Server.handle_info/2"],
        true
      ),
      oracle(
        "q4",
        "effect_intents",
        "LedgerSample.Ledger.step/2",
        [" · dispatch", " · emit"],
        true
      ),
      oracle(
        "q5",
        "effect_sites",
        "LedgerSample.EffectExecutor.execute/1",
        [" · IO.puts/1"],
        false
      ),
      oracle(
        "q6",
        "intent_interpreters",
        "LedgerSample.Ledger.step/2",
        ["execute({:dispatch", "execute({:emit"],
        true
      ),
      oracle("q7", "effect_sites", "LedgerSample.Void.execute/1", [], true)
    ]
  end

  defp oracle(id, kind, subject, expected, unknown_expected) do
    %{
      "query" => %{"id" => id, "kind" => kind, "subject" => subject},
      "expected_targets" => Enum.sort(expected),
      "unknown_expected" => unknown_expected
    }
  end
end
