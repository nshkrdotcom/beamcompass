defmodule BeamCompass.IntegrationTest do
  use ExUnit.Case, async: true

  alias BeamCompass.Analysis.Capsules
  alias BeamCompass.Model.Codec
  alias BeamCompass.Source.Scanner

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "beamcompass_integration_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "scanning does not execute Mix, module bodies, macros or on_load callbacks", %{root: root} do
    marker = Path.join(root, "executed")

    write_project(root, """
    defmodule Untrusted do
      File.write!(#{inspect(marker)}, "module")
      @on_load :boot
      def boot, do: File.write!(#{inspect(marker)}, "on_load")
      defmacro dangerous, do: File.write!(#{inspect(marker)}, "macro")
      dangerous()
      def work, do: IO.puts(:ok)
    end
    """)

    File.write!(
      Path.join(root, "mix.exs"),
      "File.write!(#{inspect(marker)}, \"mix\")\nraise \"never execute\""
    )

    assert {:ok, snapshot} = BeamCompass.scan(root)
    assert snapshot.issues == []
    assert Enum.any?(snapshot.facts, &(&1.object == "IO.puts/1"))
    refute File.exists?(marker)
  end

  test "Poncho siblings retain distinct provenance even for duplicate module names", %{root: root} do
    source = "defmodule Duplicate do\n def work, do: IO.puts(:ok)\nend"
    write_project(Path.join(root, "first"), source)
    write_project(Path.join(root, "second"), source)
    assert {:ok, first} = BeamCompass.scan(root)
    assert {:ok, second} = BeamCompass.scan(root)
    assert length(first.projects) == 2
    assert Codec.encode(first) == Codec.encode(second)
    assert Enum.map(first.projects, & &1.path) == ["first", "second"]
    effects = Enum.filter(first.facts, &(&1.kind == :effect_site))
    assert length(effects) == 2
    assert length(Enum.uniq_by(effects, & &1.id)) == 2

    assert Enum.sort(Enum.map(effects, & &1.anchor["path"])) == [
             "first/lib/demo.ex",
             "second/lib/demo.ex"
           ]
  end

  test "capsule evidence belongs to its own clause", %{root: root} do
    write_project(root, """
    defmodule Server do
      def handle_info(:first, state), do: IO.puts(state)
      def handle_info(:second, state), do: File.read(state)
    end
    """)

    assert {:ok, snapshot} = BeamCompass.scan(root)
    assert length(snapshot.capsules) == 2
    assert Capsules.build(snapshot.facts) == snapshot.capsules

    for capsule <- snapshot.capsules do
      handler = Enum.find(snapshot.facts, &(&1.id == capsule["source_fact_id"]))
      evidence = Enum.filter(snapshot.facts, &(&1.id in capsule["evidence_ids"]))
      assert Enum.all?(evidence, &(&1.details["clause"] == handler.details["clause"]))
      assert length(capsule["effect_fact_ids"]) == 1
    end
  end

  test "guards, repeated calls, tuple candidates and syntax errors preserve source evidence" do
    source = """
    defmodule Parser do
      def go(x) when is_atom(x) do
        IO.puts(x)
        IO.puts(x)
        {:dispatch, x}
      end
    end
    """

    assert {:ok, facts} = Scanner.scan(source, "lib/parser.ex")
    effects = Enum.filter(facts, &(&1.kind == :effect_site))
    assert length(effects) == 2
    assert length(Enum.uniq_by(effects, & &1.id)) == 2
    assert Enum.all?(effects, &(&1.subject == "Parser.go/1" and &1.anchor["column"] > 0))
    assert Enum.sort(Enum.map(effects, & &1.anchor["line"])) == [3, 4]
    assert Enum.any?(facts, &(&1.kind == :intent_candidate and &1.status == :proposed))
    assert {:error, reason} = Scanner.scan("defmodule Broken do", "lib/broken.ex")
    assert is_binary(reason)
  end

  test "full JSON roundtrip and a source mutation produce deterministic diffs", %{root: root} do
    write_project(root, "defmodule Mutation do\n def work, do: :ok\nend")
    assert {:ok, before} = BeamCompass.scan(root)
    assert {:ok, restored} = before |> Codec.encode() |> Codec.decode()
    assert Codec.encode(restored) == Codec.encode(before)
    assert BeamCompass.diff(before, restored)["added"] == []
    assert BeamCompass.diff(before, restored)["removed"] == []
    write_project(root, "defmodule Mutation do\n def work, do: IO.puts(:ok)\nend")
    assert {:ok, later} = BeamCompass.scan(root)
    diff = BeamCompass.diff(before, later)
    effect = Enum.find(later.facts, &(&1.kind == :effect_site))
    assert effect.id in diff["added"]
    assert diff["removed"] == []
    assert diff["before"] == before.id
    assert diff["after"] == later.id
  end

  test "parse failures are recorded as issues while other files remain usable", %{root: root} do
    write_project(root, "defmodule Good do end")
    File.write!(Path.join(root, "lib/broken.ex"), "defmodule Broken do")
    assert {:ok, snapshot} = BeamCompass.scan(root)
    assert [%{"path" => "lib/broken.ex", "reason" => reason}] = snapshot.issues
    assert is_binary(reason)
    assert Enum.any?(snapshot.facts, &(&1.subject == "Good"))
  end

  test "malformed snapshots return errors and unknown vocabulary never becomes atoms", %{
    root: root
  } do
    write_project(root, "defmodule Safe do end")
    assert {:ok, snapshot} = BeamCompass.scan(root)
    exported = Codec.export(snapshot)
    [fact | rest] = exported["facts"]
    unknown = "untrusted_kind_#{System.unique_integer([:positive])}"
    malformed = Map.put(exported, "facts", [Map.put(fact, "kind", unknown) | rest])
    assert {:error, :invalid_snapshot} = malformed |> BeamCompass.Json.encode() |> Codec.decode()
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    assert {:error, :invalid_snapshot} = Codec.decode(~s({"schema_version":1}))
    assert {:error, :unsupported_snapshot_version} = Codec.decode(~s({"schema_version":2}))
    assert {:error, _} = Codec.decode("{broken")
  end

  defp write_project(root, source) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), "raise \"target Mix must never run\"")
    File.write!(Path.join(root, "lib/demo.ex"), source)
  end
end
