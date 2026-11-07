defmodule BeamCompass.P03BRegressionTest do
  use ExUnit.Case, async: true

  alias BeamCompass.Analysis.CausalCapsules
  alias BeamCompass.Source.CausalHints

  setup do
    root = Path.join(System.tmp_dir!(), "beamcompass_p03b_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), "raise \"target Mix must stay inert\"")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "visible disconnected source cannot be marked semantically preserved", %{root: root} do
    snapshot = export(root, "defmodule Detached do\n def run, do: IO.puts(:ok)\nend")
    effect = Enum.find(snapshot["entities"], &(&1["kind"] == "effect"))
    {:ok, ref} = BeamCompass.source_reference(snapshot, "entity", effect["id"])
    {:ok, request} = BeamCompass.projection_request(snapshot, preserve: [ref], budget: 256)
    {:ok, result} = BeamCompass.project_source(snapshot, request)
    assert ref in result["visible"]
    assert ref in result["receipt"]["unsatisfied"]
    refute ref in result["receipt"]["preserved"]
    assert result["receipt"]["status"] == "unsatisfied"
    assert hd(result["receipt"]["witnesses"])["status"] == "unconnected"
  end

  test "depth and breadth frontiers disclose real cuts and retain all endpoints", %{root: root} do
    chain = Enum.map_join(0..12, "\n", &"def f#{&1}(), do: Chain.f#{&1 + 1}()")

    snapshot =
      export(root, """
      defmodule Chain do
        use GenServer
        def handle_info(:run, state), do: {Chain.f0(), state}
        #{chain}
        def f13(), do: IO.puts(:done)
      end
      """)

    [capsule] = CausalCapsules.build(snapshot)
    assert capsule["truncated"]
    assert capsule["cut_relation_ids"] != []
    closure(snapshot, capsule)

    effects = Enum.map_join(1..120, "\n", &"IO.puts(#{&1})")

    wide =
      export(root, """
      defmodule Wide do
        use GenServer
        def handle_info(:run, state) do
          #{effects}
          {:noreply, state}
        end
      end
      """)

    [breadth] = CausalCapsules.build(wide)
    assert breadth["truncated"]
    assert length(breadth["entity_ids"]) <= 96
    assert length(breadth["relation_ids"]) <= 192
    assert breadth["cut_relation_ids"] != []
    closure(wide, breadth)
  end

  test "rebound effects and handler collections refuse dataflow joins", %{root: root} do
    fixture = Path.expand("../../../fixtures/ledger_sample/lib/ledger_sample", __DIR__)

    for file <- ~w(ledger.ex effect_executor.ex server.ex) do
      File.cp!(Path.join(fixture, file), Path.join(root, "lib/#{file}"))
    end

    server = File.read!(Path.join(root, "lib/server.ex"))
    {:ok, original} = BeamCompass.export_source(root, project_id: "p03b:flow")
    assert intent_links(original) != []

    for changed <- [
          String.replace(server, "send(self(),", "effects = []\n    send(self(),"),
          String.replace(server, "Enum.each(effects,", "effects = []\n    Enum.each(effects,"),
          String.replace(server, "Enum.each(effects,", "Enum.each(state,"),
          String.replace(server, "send(self(),", "effects = List.wrap(:other)\n    send(self(),"),
          String.replace(server, "{:run_effects, effects}, state", "{:wrong_tag, effects}, state")
        ] do
      File.write!(Path.join(root, "lib/server.ex"), changed)
      {:ok, snapshot} = BeamCompass.export_source(root, project_id: "p03b:flow")
      assert intent_links(snapshot) == []
    end
  end

  test "a later alias cannot retroactively resolve an earlier function" do
    source = """
    defmodule Scope do
      def before(state), do: Ledger.step(state)
      alias Other.Ledger
      def after_alias(state), do: Ledger.step(state)
    end
    """

    hints = CausalHints.scan(source)
    refute Enum.any?(hints, &(&1.kind == :alias_call and &1.subject == "Scope.before/1"))

    assert Enum.any?(
             hints,
             &(&1.kind == :alias_call and &1.subject == "Scope.after_alias/1" and
                 &1.target == "Other.Ledger.step/1")
           )
  end

  test "literal tuple returns expose candidate state and described intent without a performer", %{
    root: root
  } do
    source = """
    defmodule TupleReducer do
      def void({used, entries}, key) do
        {{used, entries}, :voiding, [{:void, key}]}
      end
    end
    """

    before = export(root, source)
    question = %{"id" => "void", "kind" => "effect_intents", "subject" => "TupleReducer.void/2"}
    {:ok, described} = BeamCompass.answer_source(before, question)
    assert length(described["answers"]) == 1
    assert described["unknown"] != []

    assert Enum.any?(
             before["relations"],
             &(&1["kind"] == "updates_state" and &1["resolution"] == "possible")
           )

    {:ok, v1} = BeamCompass.scan(root)
    refute Enum.any?(v1.facts, &(&1.kind == :transition_candidate))
    after_snapshot = export(root, String.replace(source, "[{:void, key}]", "[]"))
    {:ok, changed} = BeamCompass.answer_source(after_snapshot, question)
    assert changed["status"] == "unknown"
    assert changed["answers"] == []

    refute Enum.any?(
             after_snapshot["relations"],
             &(&1["kind"] == "performs_effect" and &1["resolution"] == "resolved")
           )
  end

  defp export(root, source) do
    File.write!(Path.join(root, "lib/example.ex"), source)
    {:ok, snapshot} = BeamCompass.export_source(root, project_id: "p03b:regression")
    snapshot
  end

  defp intent_links(snapshot) do
    entities = Map.new(snapshot["entities"], &{&1["id"], &1})

    Enum.filter(
      snapshot["relations"],
      &(&1["kind"] == "causally_related" and entities[&1["source_id"]]["kind"] == "effect_intent")
    )
  end

  defp closure(snapshot, capsule) do
    for relation <- snapshot["relations"], relation["id"] in capsule["relation_ids"] do
      assert relation["source_id"] in capsule["entity_ids"]
      assert is_nil(relation["target_id"]) or relation["target_id"] in capsule["entity_ids"]
    end
  end
end
