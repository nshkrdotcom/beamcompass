defmodule BeamCompassTest do
  use ExUnit.Case, async: true

  alias BeamCompass.Model.{Codec, Store}
  alias BeamCompass.Source.Scanner

  @fixture Path.expand("../../../fixtures/ledger_sample", __DIR__)

  test "discovers a Mix project and builds source-grounded facts" do
    assert {:ok, snapshot} = BeamCompass.scan(@fixture)
    assert snapshot.facts != []

    assert Enum.any?(
             snapshot.facts,
             &(&1.kind == :module and &1.subject == "LedgerSample.Server")
           )

    assert Enum.any?(snapshot.facts, &(&1.kind == :role and &1.object == "GenServer"))
    assert Enum.any?(snapshot.facts, &(&1.kind == :handler))
    assert snapshot.issues == []
  end

  test "separates effect sites from merely described effect candidates" do
    assert {:ok, snapshot} = BeamCompass.scan(@fixture)
    assert Enum.any?(snapshot.facts, &(&1.kind == :effect_site and &1.object == "IO.puts/1"))
    assert Enum.any?(snapshot.facts, &(&1.kind == :intent_candidate and &1.object == "dispatch"))

    candidates = Enum.filter(snapshot.facts, &(&1.kind == :intent_candidate))
    assert Enum.all?(candidates, &(&1.status == :proposed))
  end

  test "tracks message send and an unresolved recipient rather than inventing routing" do
    assert {:ok, snapshot} = BeamCompass.scan(@fixture)
    assert Enum.any?(snapshot.facts, &(&1.kind == :message_send))
    assert Enum.any?(snapshot.facts, &(&1.kind == :unresolved))
  end

  test "produces provisional handler capsules with evidence IDs" do
    assert {:ok, snapshot} = BeamCompass.scan(@fixture)
    assert snapshot.capsules != []

    assert Enum.all?(snapshot.capsules, fn capsule ->
             capsule["status"] == "provisional" and
               capsule["coverage"] == "local_clause_only" and
               capsule["evidence_ids"] != []
           end)
  end

  test "has stable fact identities when lines shift" do
    original = "defmodule Example do\n  def work, do: IO.puts(:ok)\nend\n"
    shifted = "\n\n" <> original

    assert {:ok, first} = Scanner.scan(original, "lib/example.ex")
    assert {:ok, second} = Scanner.scan(shifted, "lib/example.ex")
    assert Enum.map(first, & &1.id) == Enum.map(second, & &1.id)
    refute Enum.map(first, & &1.anchor["line"]) == Enum.map(second, & &1.anchor["line"])
  end

  test "scan does not execute code in the input" do
    path = Path.join(System.tmp_dir!(), "beamcompass_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(path, "lib"))
    on_exit(fn -> File.rm_rf!(path) end)

    marker = Path.join(path, "marker")

    File.write!(Path.join(path, "mix.exs"), "defmodule Demo.MixProject do end\n")

    File.write!(
      Path.join(path, "lib/demo.ex"),
      "defmodule Demo do\n  File.write!(#{inspect(marker)}, \"ran\")\nend\n"
    )

    assert {:ok, _snapshot} = BeamCompass.scan(path)
    refute File.exists?(marker)
  end

  test "portable snapshot serialization is deterministic and round trips" do
    assert {:ok, snapshot} = BeamCompass.scan(@fixture)
    encoded = Codec.encode(snapshot)
    assert encoded == Codec.encode(snapshot)
    assert {:ok, restored} = Codec.decode(encoded)
    assert restored.id == snapshot.id
    assert Enum.map(restored.facts, & &1.id) == Enum.map(snapshot.facts, & &1.id)
  end

  test "portable snapshot persistence writes a usable JSON file" do
    assert {:ok, snapshot} = BeamCompass.scan(@fixture)

    filename =
      Path.join(System.tmp_dir!(), "beamcompass_#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(filename) end)

    assert :ok = Store.write(snapshot, filename)
    assert {:ok, %{id: id}} = Store.read(filename)
    assert id == snapshot.id
  end

  test "projection refuses invalid budgets and preserves omission receipts" do
    assert {:ok, snapshot} = BeamCompass.scan(@fixture)
    assert {:error, :invalid_budget} = BeamCompass.project(snapshot, budget: 0)
    assert {:error, {:unsupported_lens, :failure}} = BeamCompass.project(snapshot, lens: :failure)
    assert {:ok, view} = BeamCompass.project(snapshot, lens: :behavior, budget: 1)
    assert length(view["nodes"]) <= 1
    assert hd(view["receipts"])["omitted"] >= 0
    assert "not_a_complete_runtime_model" in view["limitations"]
  end

  test "explanation includes a source anchor and rejects unknown IDs" do
    assert {:ok, snapshot} = BeamCompass.scan(@fixture)
    first = hd(snapshot.facts)
    assert {:ok, explanation} = BeamCompass.explain(snapshot, first.id)
    assert is_integer(explanation["anchor"]["line"])
    assert {:error, :not_found} = BeamCompass.explain(snapshot, "unknown-id")
  end

  test "diff detects a newly introduced syntactic effect" do
    first_src = "defmodule Example do\n  def go, do: :ok\nend\n"
    later_src = "defmodule Example do\n  def go, do: IO.puts(:ok)\nend\n"

    assert {:ok, old_facts} = Scanner.scan(first_src, "lib/example.ex")
    assert {:ok, new_facts} = Scanner.scan(later_src, "lib/example.ex")

    old = snapshot_for(old_facts)
    new = snapshot_for(new_facts)
    difference = BeamCompass.diff(old, new)

    effect_id = Enum.find(new_facts, &(&1.kind == :effect_site)).id
    assert effect_id in difference["added"]
  end

  test "invalid Elixir is reported rather than evaluated or silently ignored" do
    assert {:error, _} = Scanner.scan("defmodule Broken do\n  def whoops(\n", "lib/broken.ex")
  end

  defp snapshot_for(facts) do
    %BeamCompass.Model.Snapshot{
      id: BeamCompass.Id.for_parts(Enum.map(facts, & &1.id)),
      projects: [],
      facts: facts,
      capsules: [],
      issues: []
    }
  end
end
