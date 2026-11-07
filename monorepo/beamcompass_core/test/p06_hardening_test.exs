defmodule BeamCompass.P06HardeningTest do
  use ExUnit.Case, async: false

  alias BeamCompass.Artifact.Migration
  alias BeamCompass.Behavior.{Archive, Export}
  alias BeamCompass.Model.{Codec, Snapshot}
  alias BeamCompass.Release.Policy
  alias BeamCompass.Source.{Provenance, Safety}

  @root Path.expand("../../../", __DIR__)

  setup do
    root =
      Path.join(System.tmp_dir!(), "beamcompass_p06_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), "raise \"untrusted target Mix must not run\"")
    File.write!(Path.join(root, "lib/sample.ex"), "defmodule P06.Sample do\n def call, do: IO.puts(:ok)\nend\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "real sibling and ledger corpora scan without running their Mix files" do
    corpora = [
      {"core", Path.join(@root, "monorepo/beamcompass_core")},
      {"web", Path.join(@root, "monorepo/beamcompass_web")},
      {"ledger", Path.join(@root, "fixtures/ledger_sample")}
    ]

    for {name, path} <- corpora do
      assert File.regular?(Path.join(path, "mix.exs"))
      assert {:ok, snapshot} = BeamCompass.export_source(path, project_id: "p06:#{name}")
      assert snapshot["schema_version"] == 2
      assert snapshot["project_id"] == "p06:#{name}"
      assert length(snapshot["entities"]) > 0
      assert Enum.all?(snapshot["evidence"], &(&1["mode"] == "source"))
      assert is_binary(snapshot["manifest"]["source_digest"])
    end
  end

  test "corpus selection rejects missing target and source symlinks", %{root: root} do
    assert {:error, _} = BeamCompass.export_source(root <> "-absent", project_id: "p06:missing")
    symlink = root <> "-symlink"
    File.ln_s!(root, symlink)
    on_exit(fn -> File.rm(symlink) end)
    assert {:error, _} = BeamCompass.export_source(symlink, project_id: "p06:symlink")

    File.ln_s!(Path.join(root, "lib/sample.ex"), Path.join(root, "lib/linked.ex"))
    assert {:error, _} = BeamCompass.export_source(root, project_id: "p06:source-symlink")
  end

  test "resource profile reports bounded source file counts and parser timeout", %{root: root} do
    limits = Safety.limits()
    assert limits["max_files"] > 0
    assert limits["parse_timeout_ms"] > 0
    assert {:ok, value} = Safety.run(fn -> %{source_only: true} end, 1_000)
    assert value.source_only
    assert {:error, :parser_timeout} = Safety.run(fn -> Process.sleep(100) end, 1)
    assert {:ok, %{inputs: inputs}} = Provenance.scan(root)
    assert length(inputs) == 1
  end

  test "oversize source and aggregate limits fail with explicit diagnostics", %{root: root} do
    limit = Safety.limits()["max_file_bytes"]
    File.write!(Path.join(root, "lib/big.ex"), String.duplicate("x", limit + 1))

    assert {:error, {:source_read_failed, "lib/big.ex", _reason}} =
             BeamCompass.export_source(root, project_id: "p06:oversize")

    assert {:error, {:source_file_limit, 2_001, 2_000}} =
             Safety.inventory([%{paths: Enum.map(1..2_001, &{&1, &1})}])

    assert {:error, {:unsafe_source_input, _, {:source_total_bytes_limit, _, _}}} =
             Safety.read(Path.join(root, "lib/sample.ex"), "lib/sample.ex", Safety.limits()["max_total_bytes"])
  end

  test "hostile target side effects remain absent under isolated source parsing", %{root: root} do
    marker = Path.join(root, "marker-do-not-create")
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/config.exs"), "File.write!(#{inspect(marker)}, \"config\")")
    File.write!(Path.join(root, "mix.exs"), "File.write!(#{inspect(marker)}, \"mix\")")

    File.write!(Path.join(root, "lib/sample.ex"), """
    defmodule Hostile do
      File.write!(#{inspect(marker)}, "module")
      @on_load :injected
      def injected, do: File.write!(#{inspect(marker)}, "on_load")
      defmacro injected_macro, do: File.write!(#{inspect(marker)}, "macro")
      injected_macro()
      def run, do: System.cmd("sh", ["-c", "touch #{marker}"])
    end
    """)

    assert {:ok, _} = BeamCompass.export_source(root, project_id: "p06:threat")
    assert {:ok, _} = BeamCompass.scan(root)
    refute File.exists?(marker)
  end

  test "compiled or observed trust requests are refused even when caller asks", %{root: root} do
    assert {:error, :unsupported_evidence_mode} =
             BeamCompass.export_source(root, project_id: "p06:trust", mode: :compiled)

    assert {:error, :unsupported_evidence_mode} =
             BeamCompass.export_source(root, project_id: "p06:trust", mode: :observed)

    assert {:error, :unsupported_snapshot_version} =
             BeamCompass.export_source(root, project_id: "p06:trust", schema: 3)
  end

  test "atomic legacy and v2 recovery retain the previous valid contents", %{root: root} do
    snapshot = legacy()
    path = Path.join(root, "prior-v1.json")
    assert :ok = BeamCompass.save(snapshot, path)
    old = File.read!(path)
    assert {:ok, ^snapshot} = BeamCompass.load(path)

    # Failed replacement points at an invalid directory; valid prior content stays exact.
    assert {:error, _} = BeamCompass.save(snapshot, root)
    assert File.read!(path) == old

    assert {:ok, %{snapshot: v2, inputs: inputs}} = Export.scan(root, "p06:recovery")
    assert {:ok, record} = Archive.put(v2, inputs, Path.join(root, "archive"))
    assert {:ok, bundle} = Archive.get(Path.join(root, "archive"), record["content_id"])
    assert {:ok, ^v2} = Archive.rehydrate(bundle)
    before = File.read!(record["path"])
    assert {:error, _} = Archive.get(Path.join(root, "archive"), String.duplicate("f", 64))
    assert File.read!(record["path"]) == before
  end

  test "corrupt unsupported and symlink archives reject without changing data", %{root: root} do
    assert :ok = BeamCompass.save(legacy(), Path.join(root, "v1.json"))
    old = File.read!(Path.join(root, "v1.json"))
    assert {:error, :unsupported_snapshot_version} = Codec.decode(~s({"schema_version":99}))
    assert {:error, _} = Codec.decode("broken-json")

    assert {:ok, %{snapshot: v2, inputs: inputs}} = Export.scan(root, "p06:bad")
    assert {:ok, record} = Archive.put(v2, inputs, Path.join(root, "archive"))
    assert {:ok, bundle} = Archive.get(Path.join(root, "archive"), record["content_id"])
    assert {:error, :unsupported_archive_version} = Archive.validate(%{bundle | "schema_version" => 3})
    assert {:error, :archive_hash_mismatch} =
             Archive.validate(%{bundle | "content_id" => String.duplicate("0", 64)})

    secret = Path.join(root, "prior-secret")
    File.write!(secret, "do not read or overwrite")
    File.rm!(record["path"])
    File.ln_s!(secret, record["path"])
    assert {:error, :unsafe_archive_file_type} = Archive.get(Path.join(root, "archive"), record["content_id"])
    assert {:error, :unsafe_archive_file_type} = Archive.put(v2, inputs, Path.join(root, "archive"))
    assert File.read!(secret) == "do not read or overwrite"
    assert File.read!(Path.join(root, "v1.json")) == old

    v1_symlink = Path.join(root, "symlink-v1.json")
    File.ln_s!(secret, v1_symlink)
    assert {:error, :unsafe_output_file_type} = BeamCompass.save(legacy(), v1_symlink)
    assert File.read!(secret) == "do not read or overwrite"
    assert File.read!(Path.join(root, "v1.json")) == old
  end

  test "deterministic release fingerprint is stable for same inputs" do
    a = %{"corpus" => ["core", "web", "ledger"], "kind" => "source"}
    b = %{"kind" => "source", "corpus" => ["core", "web", "ledger"]}
    assert Policy.fingerprint(a) == Policy.fingerprint(b)
    refute Policy.fingerprint(a) == Policy.fingerprint(%{b | "kind" => "observed"})
  end

  test "release gate refuses unapproved thresholds and open high severity" do
    assert {:error, %{ "blockers" => blockers}} = Policy.evaluate(measure(), nil, [])
    assert "missing_owner_approved_thresholds" in blockers

    assert {:error, %{"blockers" => risk_blockers}} =
             Policy.evaluate(measure(), synthetic_approval(), [%{"severity" => "critical", "status" => "open"}])

    assert "open_high_severity_blocker" in risk_blockers
  end

  test "release policy reports observed limitations and measured release status" do
    # This synthetic approval is only a unit test of policy logic, NOT project owner signoff.
    assert {:ok, result} = Policy.evaluate(measure(), synthetic_approval(), [])
    assert result["release_eligible"] == true
    assert is_binary(result["measurement_fingerprint"])
    assert {:error, %{"blockers" => limits}} =
             Policy.evaluate(%{measure() | "wall_ms" => 10_000}, synthetic_approval(), [])
    assert "budget_exceeded:wall_ms" in limits
  end

  test "release criteria reject missing measurements and missing provenance" do
    assert {:error, %{"blockers" => missing}} = Policy.evaluate(%{}, %{}, [])
    assert "missing_or_untrusted_measurements" in missing
    assert "missing_owner_approved_thresholds" in missing

    assert {:error, %{"blockers" => source}} =
             Policy.evaluate(%{measure() | "source_mode" => "observed"}, synthetic_approval(), [])
    assert "missing_or_untrusted_measurements" in source
  end

  test "old supported snapshot migration envelopes rehydrate with no fabricated provenance", %{root: root} do
    old = legacy()
    assert {:ok, envelope} = Migration.wrap(old)
    assert envelope["loss"] == []
    assert envelope["migration_status"] == "lossless_transport_only"
    assert {:ok, ^old} = Migration.rehydrate(envelope)

    assert {:ok, %{snapshot: v2}} = Export.scan(root, "p06:migrate")
    assert {:ok, wrapped_v2} = Migration.wrap(v2)
    assert {:ok, ^v2} = Migration.rehydrate(wrapped_v2)
    assert wrapped_v2["source_format"] == "v2_snapshot"
  end

  test "v2 promotion and corrupted compatibility envelopes refuse without data loss", %{root: root} do
    old = legacy()
    assert {:ok, wrapped} = Migration.wrap(old)
    assert {:error, %{"reason" => "source_reextraction_required", "loss" => loss}} =
             Migration.promote(old, 2)
    assert "v2_source_hashes" in loss

    assert {:ok, %{snapshot: v2}} = Export.scan(root, "p06:no-downgrade")
    assert {:error, %{"reason" => "semantic_downgrade_unsupported"}} = Migration.promote(v2, 1)
    assert {:error, :compatibility_hash_mismatch} =
             Migration.rehydrate(%{wrapped | "content_sha256" => String.duplicate("f", 64)})
    assert {:error, :unacknowledged_migration_loss} =
             Migration.rehydrate(%{wrapped | "loss" => ["unknown-fields"]})

    assert {:ok, ^old} = Migration.rehydrate(wrapped)
  end

  defp legacy do
    %Snapshot{id: "p06-legacy", projects: [], facts: [], capsules: [], issues: []}
  end

  defp measure do
    %{
      "wall_ms" => 20,
      "rss_bytes" => 2_000,
      "source_files" => 10,
      "recovery_ms" => 15,
      "recovery_data_intact" => true,
      "source_mode" => "source",
      "corpus_ids" => ["core", "web", "ledger"]
    }
  end

  defp synthetic_approval do
    %{
      "approved" => true,
      "owner" => "synthetic-fixture-only-not-real-approval",
      "max_wall_ms" => 1_000,
      "max_rss_bytes" => 10_000,
      "max_source_files" => 200,
      "max_recovery_ms" => 1_000
    }
  end
end
