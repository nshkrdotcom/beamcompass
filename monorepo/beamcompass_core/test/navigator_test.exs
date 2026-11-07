defmodule BeamCompass.NavigatorTest do
  use ExUnit.Case, async: true

  alias BeamCompass.Analysis.Navigator
  alias BeamCompass.Behavior.{Export, Store, Validator}

  @fixture Path.expand("../../../fixtures/ledger_sample", __DIR__)

  setup_all do
    assert {:ok, %{snapshot: snapshot}} = Export.scan(@fixture, "test:p05:source")
    assert :ok = Validator.validate(snapshot)
    entity = hd(snapshot["entities"])
    evidence = hd(entity["evidence_ids"])
    {:ok, snapshot: snapshot, entity: entity, evidence: evidence}
  end

  test "core navigator emits typed projection and stable evidence view", %{snapshot: snapshot} do
    assert {:ok, view} = Navigator.view(snapshot, %{"lens" => "behavior", "budget" => "256"})
    assert view["format"] == "beamcompass.navigator.view"
    assert view["status"] == "available"
    assert view["project_id"] == snapshot["project_id"]
    assert view["snapshot_id"] == snapshot["snapshot_id"]
    assert view["projection"]["request"]["snapshot_id"] == snapshot["snapshot_id"]
    assert length(view["stage"]["nodes"]) == length(view["projection"]["visible"])
    assert Enum.map(view["stage"]["nodes"], & &1["reference"]) == view["projection"]["visible"]
    assert Enum.all?(view["stage"]["edges"], &(&1["reference"]["object_kind"] == "relation"))
    assert Enum.all?(view["stage"]["edges"], &(&1["resolution"] in ~w(resolved possible unresolved)))
  end

  test "core navigator refuses unsupported lenses and injected query keys", %{snapshot: snapshot} do
    assert {:error, :unsupported_navigation_lens} = Navigator.view(snapshot, %{"lens" => "grand_approval"})
    assert {:error, :unsupported_navigation_field} = Navigator.view(snapshot, %{"approve" => "true"})
    assert {:error, :invalid_navigation_budget} = Navigator.view(snapshot, %{"budget" => "99999"})
    assert {:error, :invalid_navigation_budget} = Navigator.view(snapshot, %{"budget" => "-1"})
    assert {:error, :duplicate_navigation_field} = Navigator.from_query(snapshot, "lens=state&lens=effects")
    assert {:error, :incomplete_selection_identity} = Navigator.view(snapshot, %{"selected_id" => "e"})
  end

  test "exact selection opens source anchor and lineage evidence drawer", context do
    s = context.snapshot
    entity = context.entity
    query = %{"selected_kind" => "entity", "selected_id" => entity["id"]}
    assert {:ok, view} = Navigator.view(s, query)
    assert view["selection"]["object_id"] == entity["id"]
    assert view["drawer"]["record"]["id"] == entity["id"]
    assert Enum.map(view["drawer"]["evidence"], & &1["id"]) == entity["evidence_ids"]
    assert Enum.all?(view["drawer"]["evidence"], fn evidence ->
             evidence["mode"] == "source" and is_integer(evidence["anchor"]["start_line"]) and
               evidence["anchor"]["end_line"] == nil and
               evidence["reference"]["snapshot_id"] == s["snapshot_id"]
           end)
    assert is_list(view["drawer"]["related"])
  end

  test "missing selected record reports unavailable target without label remap", %{snapshot: snapshot} do
    assert {:ok, view} = Navigator.view(snapshot, %{"selected_kind" => "entity", "selected_id" => "same-looking-missing"})
    assert view["status"] == "unavailable"
    assert hd(view["diagnostics"])["code"] == "selected_target_unavailable"
    assert view["stage"]["nodes"] == []
    assert view["drawer"] == nil
    assert view["projection"] == nil
    assert {:ok, focus_missing} = Navigator.view(snapshot, %{"focus_kind" => "entity", "focus_id" => "gone"})
    assert hd(focus_missing["diagnostics"])["code"] == "focus_target_unavailable"
  end

  test "semantic budget zoom preserves atomic receipts and unknowns", %{snapshot: snapshot} do
    assert {:ok, small} = Navigator.view(snapshot, %{"budget" => "1", "lens" => "effects"})
    assert {:ok, large} = Navigator.view(snapshot, %{"budget" => "256", "lens" => "effects"})
    assert small["projection"]["receipt"]["counts"]["visible"] <= 1
    assert large["projection"]["receipt"]["counts"]["visible"] >= small["projection"]["receipt"]["counts"]["visible"]
    assert length(small["projection"]["omitted"]) >= length(large["projection"]["omitted"])
    assert small["projection"]["receipt"]["status"] in ~w(satisfied unsatisfied)
    assert Enum.all?(small["projection"]["unknown"], &(&1["reason"] == "unresolved_source_relation"))
    assert small["navigation"]["zoom_in"] =~ "budget=2"
  end

  test "tight budget records omitted witnesses without completeness claim", %{snapshot: snapshot, entity: entity} do
    q = %{"selected_kind" => "entity", "selected_id" => entity["id"], "budget" => "1"}
    assert {:ok, view} = Navigator.view(snapshot, q)
    receipt = view["projection"]["receipt"]
    assert receipt["counts"]["visible"] <= 1
    assert length(view["projection"]["omitted"]) == receipt["counts"]["omitted"]
    assert receipt["completeness"] != "runtime_complete"
    assert Enum.any?(receipt["limitations"], &String.contains?(&1, "runtime"))
    assert Enum.all?(receipt["unsatisfied"], &(&1["snapshot_id"] == snapshot["snapshot_id"]))
  end

  test "pinned deep link round trips exact selection and lens", %{snapshot: snapshot, entity: entity} do
    q = %{"selected_kind" => "entity", "selected_id" => entity["id"], "budget" => "8", "lens" => "state"}
    assert {:ok, first} = Navigator.view(snapshot, q)
    raw = String.trim_leading(first["navigation"]["self"], "?")
    assert {:ok, ^first} = Navigator.from_query(snapshot, raw)
    assert first["navigation"]["self"] =~ URI.encode_www_form(snapshot["snapshot_id"])
    assert first["selection"]["object_id"] == entity["id"]
  end

  test "wrong snapshot deep link refuses rebinding to a similar object", %{snapshot: snapshot} do
    assert {:ok, unavailable} = Navigator.view(snapshot, %{"snapshot" => String.duplicate("0", 64)})
    assert unavailable["status"] == "unavailable"
    assert hd(unavailable["diagnostics"])["code"] == "snapshot_unavailable"
    assert unavailable["stage"] == %{"nodes" => [], "edges" => []}
    assert unavailable["projection"] == nil
    assert {:ok, other} = Navigator.view(snapshot, %{"project" => "another:project"})
    assert hd(other["diagnostics"])["code"] == "project_unavailable"
  end

  test "source evidence lineage links are exact and never inferred in the UI", %{snapshot: snapshot, entity: entity} do
    assert {:ok, view} =
             Navigator.view(snapshot, %{"selected_kind" => "entity", "selected_id" => entity["id"]})

    assert Enum.all?(view["drawer"]["evidence"], fn evidence ->
             Enum.map(evidence["lineage"], & &1["id"]) == evidence["input_evidence_ids"] and
               Enum.all?(evidence["lineage"], fn parent ->
                 {:ok, pinned} = Navigator.from_query(snapshot, String.trim_leading(parent["href"], "?"))
                 pinned["selection"]["object_id"] == parent["id"] and
                   pinned["selection"]["object_kind"] == "evidence"
               end)
           end)
  end

  test "source questions are typed exact focus links and never claim execution", %{snapshot: snapshot} do
    assert {:ok, view} = Navigator.view(snapshot, %{"lens" => "behavior", "budget" => "8"})
    assert is_list(view["questions"])
    assert length(view["questions"]) >= 4
    assert Enum.all?(view["questions"], fn question ->
             question["source_scope"] == "bounded_source_only" and
               String.starts_with?(question["href"], "?") and
               is_binary(question["title"])
           end)

    for question <- view["questions"] do
      assert {:ok, opened} = Navigator.from_query(snapshot, String.trim_leading(question["href"], "?"))
      assert opened["status"] == "available"
      assert opened["project_id"] == snapshot["project_id"]
      assert opened["snapshot_id"] == snapshot["snapshot_id"]
      assert opened["focus"] == opened["selection"]
    end
  end

  test "source question from a different revision is explicitly unavailable", %{snapshot: snapshot} do
    assert {:ok, view} = Navigator.view(snapshot)
    [question | _] = view["questions"]
    forged = String.replace(question["href"], "snapshot=" <> snapshot["snapshot_id"],
              "snapshot=" <> String.duplicate("f", 64))
    assert {:ok, refused} = Navigator.from_query(snapshot, String.trim_leading(forged, "?"))
    assert refused["status"] == "unavailable"
    assert hd(refused["diagnostics"])["code"] == "snapshot_unavailable"
    assert refused["questions"] == []
    assert refused["stage"]["nodes"] == []
  end

  test "headless exported view matches browser server selection semantics", %{snapshot: snapshot, evidence: id} do
    query = %{"lens" => "failure", "selected_kind" => "evidence", "selected_id" => id}
    assert {:ok, from_core} = BeamCompass.navigator_view(snapshot, query)
    assert {:ok, from_query} = Navigator.from_query(snapshot, Navigator.query_string(query))
    assert from_core == from_query
    assert from_core["drawer"]["reference"]["object_kind"] == "evidence"
    assert (from_core["drawer"]["evidence"] |> hd() |> Map.fetch!("id")) == id
    assert JasonlessRoundtrip.roundtrip(from_core) == from_core
  end

  test "headless export refuses invalid source data and stale identity", %{snapshot: snapshot} do
    bad = Map.put(snapshot, "snapshot_id", String.duplicate("f", 64))
    assert {:error, :snapshot_hash_mismatch} = Navigator.view(bad)
    assert {:ok, missing} = Navigator.from_query(snapshot, "snapshot=unavailable&selected_kind=relation&selected_id=unknown")
    assert missing["status"] == "unavailable"
    assert missing["drawer"] == nil
    assert {:error, :invalid_selection_identity} = Navigator.view(snapshot, %{"selected_kind" => "untrusted_atom", "selected_id" => "x"})
    root = System.tmp_dir!()
    path = Path.join(root, "beamcompass-navigator-#{System.unique_integer([:positive])}.json")
    assert :ok = Store.write(snapshot, path)
    assert {:ok, decoded} = File.read(path) |> elem(1) |> JSON.decode()
    assert decoded == snapshot
    File.rm!(path)
  end

  defmodule JasonlessRoundtrip do
    def roundtrip(map) do
      {:ok, decoded} = map |> BeamCompass.Json.encode() |> JSON.decode()
      decoded
    end
  end
end
