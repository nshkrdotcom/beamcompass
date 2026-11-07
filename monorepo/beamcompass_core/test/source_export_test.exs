defmodule BeamCompass.SourceExportTest do
  use ExUnit.Case, async: true

  alias BeamCompass.Behavior.{Export, Validator}
  alias BeamCompass.Json
  alias BeamCompass.Model.Codec
  alias BeamCompass.Source.Provenance

  setup do
    root =
      Path.join(System.tmp_dir!(), "beamcompass_export_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "actual ledger fixture contains sourced effect sites and distinct proposed intents" do
    root = Path.expand("../../../fixtures/ledger_sample", __DIR__)
    assert {:ok, snapshot} = BeamCompass.export_source(root, project_id: "fixture:ledger")
    assert snapshot["schema_version"] == 2
    assert snapshot["project_id"] == "fixture:ledger"
    assert :ok = Validator.validate(snapshot)
    assert snapshot["manifest"]["providers"] |> hd() |> Map.fetch!("mode") == "source"

    entities = Map.new(snapshot["entities"], &{&1["id"], &1})
    assert Enum.any?(snapshot["entities"], &(&1["kind"] == "actor"))
    assert Enum.any?(snapshot["entities"], &(&1["kind"] == "trigger"))
    assert Enum.any?(snapshot["entities"], &(&1["kind"] == "transition"))
    assert Enum.any?(snapshot["entities"], &(&1["kind"] == "effect_intent"))
    assert Enum.any?(snapshot["entities"], &(&1["kind"] == "effect"))

    resolved =
      Enum.filter(
        snapshot["relations"],
        &(&1["kind"] == "performs_effect" and &1["resolution"] == "resolved")
      )

    unknown =
      Enum.filter(
        snapshot["relations"],
        &(&1["kind"] == "performs_effect" and &1["resolution"] == "unresolved")
      )

    assert resolved != []
    assert unknown != []
    assert Enum.all?(resolved, &(entities[&1["target_id"]]["kind"] == "effect"))
    assert Enum.all?(unknown, &is_nil(&1["target_id"]))
    assert Enum.any?(snapshot["relations"], &(&1["kind"] == "describes_effect"))

    for record <- snapshot["evidence"] do
      assert record["mode"] == "source"
      assert record["anchor"]["end_line"] == nil
      assert record["anchor"]["end_column"] == nil
      refute String.starts_with?(record["anchor"]["path"], "/")
    end

    first = hd(resolved)
    assert {:ok, reference} = BeamCompass.source_reference(snapshot, "relation", first["id"])
    assert {:ok, ^first} = BeamCompass.resolve_source_reference(snapshot, reference)
    assert reference["evidence_ids"] == first["evidence_ids"]
  end

  test "one fresh scan returns exact file-hash and settings manifests, with deterministic output",
       %{root: root} do
    write_project(root, """
    defmodule Typed do
      def step(state) when is_map(state) do
        Map.put(state, :a, 1)
        IO.puts("ready")
        {:dispatch, :notify}
      end
    end
    """)

    assert {:ok, first} = Export.scan(root, "test:typed")
    assert {:ok, second} = Export.scan(root, "test:typed")
    assert Json.encode(first.snapshot) == Json.encode(second.snapshot)
    assert first.snapshot["snapshot_id"] == Validator.fingerprint(first.snapshot)
    assert first.inputs == second.inputs
    assert first.settings == second.settings

    assert first.snapshot["manifest"]["source_digest"] ==
             Provenance.sha256(Json.encode(first.inputs))

    assert first.snapshot["manifest"]["config_digest"] ==
             Provenance.sha256(Json.encode(first.settings))

    assert [%{"path" => "lib/demo.ex", "sha256" => sha}] = first.inputs
    assert sha == Provenance.sha256(File.read!(Path.join(root, "lib/demo.ex")))

    first_path = Path.join(root, "first.json")
    second_path = Path.join(root, "second.json")
    assert :ok = BeamCompass.save_source(first.snapshot, first_path)
    assert :ok = BeamCompass.save_source(second.snapshot, second_path)
    assert File.read!(first_path) == File.read!(second_path)

    File.write!(
      Path.join(root, "lib/demo.ex"),
      File.read!(Path.join(root, "lib/demo.ex")) <> "\n"
    )

    assert {:ok, changed} = BeamCompass.export_source(root, project_id: "test:typed")
    refute changed["snapshot_id"] == first.snapshot["snapshot_id"]
    refute changed["manifest"]["source_digest"] == first.snapshot["manifest"]["source_digest"]
  end

  test "v1 scanner serialization and public API stay independent of v2", %{root: root} do
    write_project(root, "defmodule Old do\n def work, do: IO.puts(:ok)\nend")
    assert {:ok, v1} = BeamCompass.scan(root)
    encoded = Codec.encode(v1)
    assert {:ok, decoded} = Codec.decode(encoded)
    assert Codec.encode(decoded) == encoded
    assert {:ok, _v2} = BeamCompass.export_source(root, project_id: "test:old")
    assert {:ok, decoded} = Codec.decode(encoded)
    assert Codec.encode(decoded) == encoded
    assert {:error, :missing_provenance} = BeamCompass.export_source(v1, project_id: "test:old")
    assert {:error, :project_id_required} = BeamCompass.export_source(root)

    assert {:error, :unsupported_evidence_mode} =
             BeamCompass.export_source(root, project_id: "test:old", mode: :observed)

    assert {:error, :unsupported_evidence_mode} =
             BeamCompass.export_source(root, project_id: "test:old", mode: :compiled)

    assert {:error, :unsupported_snapshot_version} =
             BeamCompass.export_source(root, project_id: "test:old", schema: 1)

    assert {:error, :unsupported_export_option} =
             BeamCompass.export_source(root, project_id: "test:old", approval: true)

    assert {:error, :unsupported_snapshot_version} =
             Codec.decode(Json.encode(%{"schema_version" => 2}))
  end

  test "rehashed, source-only masquerade and wrong effect endpoint are rejected", %{root: root} do
    write_project(root, """
    defmodule Safe do
      def perform, do: IO.puts(:ok)
      def describe, do: {:dispatch, :notify}
    end
    """)

    assert {:ok, snapshot} = BeamCompass.export_source(root, project_id: "test:safe")

    altered_provider =
      put_in(snapshot, ["manifest", "providers", Access.at(0), "mode"], "observed") |> rehash()

    assert {:error, :invalid_provider} = Validator.validate(altered_provider)

    altered_evidence =
      update_in(snapshot, ["evidence"], fn [first | others] ->
        [Map.put(first, "mode", "compiled") | others]
      end)
      |> rehash()

    assert {:error, :invalid_evidence} = Validator.validate(altered_evidence)

    intent = Enum.find(snapshot["entities"], &(&1["kind"] == "effect_intent"))
    effect = Enum.find(snapshot["entities"], &(&1["kind"] == "effect"))

    performer =
      Enum.find(
        snapshot["relations"],
        &(&1["kind"] == "performs_effect" and &1["resolution"] == "resolved")
      )

    descriptor = Enum.find(snapshot["relations"], &(&1["kind"] == "describes_effect"))

    bad_performer = replace_relation(snapshot, performer["id"], "target_id", intent["id"])
    assert {:error, :invalid_relation} = Validator.validate(bad_performer)
    bad_descriptor = replace_relation(snapshot, descriptor["id"], "target_id", effect["id"])
    assert {:error, :invalid_relation} = Validator.validate(bad_descriptor)

    assert {:ok, reference} = BeamCompass.source_reference(snapshot, "entity", effect["id"])

    assert {:error, :wrong_reference_namespace} =
             BeamCompass.resolve_source_reference(
               snapshot,
               Map.put(reference, "project_id", "other")
             )

    assert {:error, :not_found} =
             BeamCompass.resolve_source_reference(
               snapshot,
               Map.put(reference, "object_id", "effect label")
             )

    assert {:error, :unrelated_evidence} =
             BeamCompass.resolve_source_reference(
               snapshot,
               Map.put(reference, "evidence_ids", intent["evidence_ids"])
             )

    assert {:error, :unrelated_evidence} =
             BeamCompass.resolve_source_reference(
               snapshot,
               Map.put(reference, "evidence_ids", [])
             )
  end

  test "removed direct performer versus unchanged unknown intent produce distinct data", %{
    root: root
  } do
    write_project(root, """
    defmodule Contrast do
      def describe, do: {:emit, :message}
      def interpreter, do: IO.puts(:message)
    end
    """)

    assert {:ok, before} = BeamCompass.export_source(root, project_id: "test:contrast")

    assert Enum.any?(
             before["relations"],
             &(&1["kind"] == "performs_effect" and &1["resolution"] == "resolved")
           )

    write_project(root, """
    defmodule Contrast do
      def describe, do: {:emit, :message}
      def interpreter, do: :ok
    end
    """)

    assert {:ok, later} = BeamCompass.export_source(root, project_id: "test:contrast")

    refute Enum.any?(
             later["relations"],
             &(&1["kind"] == "performs_effect" and &1["resolution"] == "resolved")
           )

    assert Enum.any?(
             later["relations"],
             &(&1["kind"] == "performs_effect" and &1["resolution"] == "unresolved")
           )
  end

  test "standalone, siblings and monorepo paths isolate duplicate module names", %{root: root} do
    for prefix <- ["first", "second", "monorepo/core", "monorepo/web"] do
      write_project(
        Path.join(root, prefix),
        "defmodule Duplicate do\n def run, do: IO.puts(:ok)\nend"
      )
    end

    assert {:ok, all} = BeamCompass.export_source(root, project_id: "test:poncho")
    assert length(all["entities"] |> Enum.filter(&(&1["kind"] == "effect"))) == 4
    assert length(all["evidence"] |> Enum.map(& &1["anchor"]["path"]) |> Enum.uniq()) == 4

    assert {:ok, subtree} =
             BeamCompass.export_source(Path.join(root, "monorepo"), project_id: "test:poncho")

    assert length(subtree["entities"] |> Enum.filter(&(&1["kind"] == "effect"))) == 2
    assert Enum.any?(subtree["evidence"], &String.starts_with?(&1["anchor"]["path"], "core/lib/"))

    assert Enum.any?(
             all["evidence"],
             &String.starts_with?(&1["anchor"]["path"], "monorepo/core/lib/")
           )
  end

  test "hostile target mix, module body, on_load and macros remain unexecuted", %{root: root} do
    marker = Path.join(root, "executed.marker")

    write_project(root, """
    defmodule Hostile do
      File.write!(#{inspect(marker)}, "body")
      @on_load :boot
      def boot, do: File.write!(#{inspect(marker)}, "on_load")
      defmacro trigger, do: File.write!(#{inspect(marker)}, "macro")
      trigger()
      def work, do: IO.puts(:ok)
    end
    """)

    File.write!(
      Path.join(root, "mix.exs"),
      "File.write!(#{inspect(marker)}, \"mix\")\nraise \"never\""
    )

    assert {:ok, snapshot} = BeamCompass.export_source(root, project_id: "test:hostile")
    assert :ok = Validator.validate(snapshot)
    refute File.exists?(marker)
  end

  test "consumer-integrity rejections include unsafe anchors, cycles and dangling evidence", %{
    root: root
  } do
    write_project(root, "defmodule Strict do\n def run, do: IO.puts(:ok)\nend")
    assert {:ok, original} = BeamCompass.export_source(root, project_id: "test:integrity")
    [first | rest] = original["evidence"]

    unsafe =
      original
      |> Map.put("evidence", [put_in(first, ["anchor", "path"], "../private") | rest])
      |> rehash()

    assert {:error, :invalid_evidence} = Validator.validate(unsafe)

    cyclic =
      original
      |> Map.put("evidence", [Map.put(first, "input_evidence_ids", [first["id"]]) | rest])
      |> rehash()

    assert {:error, :cyclic_evidence} = Validator.validate(cyclic)

    [entity | rest_entities] = original["entities"]

    dangling =
      original
      |> Map.put("entities", [
        Map.put(entity, "evidence_ids", ["missing-evidence"]) | rest_entities
      ])
      |> rehash()

    assert {:error, :invalid_entity} = Validator.validate(dangling)
  end

  test "invalid source is a recorded issue and failed writes never replace existing export", %{
    root: root
  } do
    write_project(root, "defmodule Good do end")
    File.write!(Path.join(root, "lib/broken.ex"), "defmodule Broken do")
    assert {:ok, snapshot} = BeamCompass.export_source(root, project_id: "test:issues")
    assert [%{"code" => "parse_error"}] = snapshot["issues"]
    assert :ok = Validator.validate(snapshot)
    target = Path.join(root, "out.json")
    assert :ok = BeamCompass.save_source(snapshot, target)
    expected = File.read!(target)
    wrong = Map.put(snapshot, "snapshot_id", String.duplicate("0", 64))
    assert {:error, :snapshot_hash_mismatch} = BeamCompass.save_source(wrong, target)
    assert File.read!(target) == expected
  end

  test "Unicode columns count code points and retain start-only precision", %{root: root} do
    line = ~s|  def run, do: ("é🌈"; IO.puts(:ok))|
    write_project(root, "defmodule UnicodeExample do\n" <> line <> "\nend\n")
    assert {:ok, snapshot} = BeamCompass.export_source(root, project_id: "test:unicode")
    {prefix, _} = :binary.match(line, "puts")
    expected = line |> binary_part(0, prefix) |> String.to_charlist() |> length() |> Kernel.+(1)

    assert Enum.any?(snapshot["evidence"], fn ev ->
             anchor = ev["anchor"]

             anchor["start_line"] == 2 and anchor["start_column"] == expected and
               is_nil(anchor["end_line"]) and is_nil(anchor["end_column"])
           end)
  end

  defp rehash(snapshot), do: Map.put(snapshot, "snapshot_id", Validator.fingerprint(snapshot))

  defp replace_relation(snapshot, id, key, value) do
    snapshot
    |> Map.update!("relations", fn items ->
      Enum.map(items, &replace_item(&1, id, key, value))
    end)
    |> rehash()
  end

  defp replace_item(%{"id" => id} = item, id, key, value), do: Map.put(item, key, value)
  defp replace_item(item, _, _, _), do: item

  defp write_project(root, content) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), "raise \"never execute target mix\"")
    File.write!(Path.join(root, "lib/demo.ex"), content)
  end
end
