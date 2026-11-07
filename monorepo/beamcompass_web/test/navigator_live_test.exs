defmodule BeamCompassWeb.NavigatorLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias BeamCompass.Behavior.{Export, Store, Validator}
  alias BeamCompassWeb.NavigatorSource

  @endpoint BeamCompassWeb.Endpoint
  @fixture Path.expand("../../../fixtures/ledger_sample", __DIR__)

  setup do
    assert {:ok, %{snapshot: snapshot}} = Export.scan(@fixture, "test:navigator:live")
    path = Path.join(System.tmp_dir!(), "bc_live_#{System.unique_integer([:positive])}.json")
    assert :ok = Store.write(snapshot, path)
    previous = Application.get_env(:beamcompass_web, :navigator_snapshot_path)
    Application.put_env(:beamcompass_web, :navigator_snapshot_path, path)

    on_exit(fn ->
      if previous do
        Application.put_env(:beamcompass_web, :navigator_snapshot_path, previous)
      else
        Application.delete_env(:beamcompass_web, :navigator_snapshot_path)
      end

      File.rm(path)
    end)

    {:ok, snapshot: snapshot, path: path}
  end

  test "liveview mounts a validated archived source snapshot and keeps offline reports", %{
    snapshot: snapshot
  } do
    {:ok, live_view, html} = live(build_conn(), "/navigator?lens=effects&budget=4")
    assert html =~ "Source view"
    assert html =~ snapshot["snapshot_id"]
    assert has_element?(live_view, "#semantic-stage[data-view]")
    assert has_element?(live_view, "#projection-receipts")
    assert has_element?(live_view, "nav[aria-label='Source view lenses']")
    assert has_element?(live_view, "nav[aria-label='Source-grounded questions'] a")
    assert function_exported?(BeamCompassWeb.Report, :render, 1)
  end

  test "liveview refuses absent snapshot input without executing a target", %{path: path} do
    Application.put_env(:beamcompass_web, :navigator_snapshot_path, path <> ".missing")
    {:ok, live_view, html} = live(build_conn(), "/navigator")
    assert html =~ "Snapshot or navigation unavailable"
    assert has_element?(live_view, "#navigator-error[role='alert']")
    refute html =~ "Source view ·"
  end

  test "liveview renders authoritative receipt and selection contract", %{snapshot: snapshot} do
    entity = hd(snapshot["entities"])
    url = "/navigator?selected_kind=entity&selected_id=" <> URI.encode_www_form(entity["id"])
    {:ok, live_view, html} = live(build_conn(), url)
    assert html =~ "Source &amp; evidence"
    assert html =~ entity["id"]
    assert has_element?(live_view, "#preservation-status")
    assert has_element?(live_view, "#source-drawer .evidence-row")
    assert has_element?(live_view, "details summary", "Omitted source records")
  end

  test "liveview escapes hostile labels and refuses unavailable target", %{
    snapshot: snapshot,
    path: path
  } do
    entity = hd(snapshot["entities"])

    altered = %{
      snapshot
      | "entities" =>
          Enum.map(snapshot["entities"], fn item ->
            if item["id"] == entity["id"],
              do: %{item | "label" => "<script>alert('owned')</script>"},
              else: item
          end)
    }

    altered = Map.put(altered, "snapshot_id", Validator.fingerprint(altered))
    assert :ok = Validator.validate(altered)
    assert :ok = Store.write(altered, path)
    url = "/navigator?selected_kind=entity&selected_id=" <> URI.encode_www_form(entity["id"])
    {:ok, _live_view, html} = live(build_conn(), url)
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>alert('owned')</script>"

    {:ok, bad, bad_html} =
      live(build_conn(), "/navigator?selected_kind=entity&selected_id=not-a-real-record")

    assert has_element?(bad, "#unavailable-target[role='alert']")
    assert bad_html =~ "selected_target_unavailable"
    refute bad_html =~ "#source-drawer"
  end

  test "archived source revision switches only through a validated exact-ID catalog", %{
    snapshot: snapshot
  } do
    [first | rest] = snapshot["entities"]

    revised = %{
      snapshot
      | "entities" => [%{first | "label" => first["label"] <> " revised"} | rest]
    }

    revised = Map.put(revised, "snapshot_id", Validator.fingerprint(revised))
    assert :ok = Validator.validate(revised)

    directory = Path.join(System.tmp_dir!(), "bc_revisions_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    filename = Path.join(directory, revised["snapshot_id"] <> ".json")
    assert :ok = Store.write(revised, filename)
    prior = Application.get_env(:beamcompass_web, :navigator_catalog_dir)
    Application.put_env(:beamcompass_web, :navigator_catalog_dir, directory)

    on_exit(fn ->
      if prior do
        Application.put_env(:beamcompass_web, :navigator_catalog_dir, prior)
      else
        Application.delete_env(:beamcompass_web, :navigator_catalog_dir)
      end

      File.rm_rf(directory)
    end)

    assert {:ok, ^revised} =
             NavigatorSource.select(snapshot, %{"snapshot" => revised["snapshot_id"]})

    assert length(NavigatorSource.revisions(snapshot)) == 2
    url = "/navigator?snapshot=" <> revised["snapshot_id"]
    {:ok, live_view, html} = live(build_conn(), url)
    assert html =~ revised["snapshot_id"]
    assert has_element?(live_view, "nav[aria-label='Archived source revisions']")
    assert has_element?(live_view, "#semantic-stage")
    {:ok, missing, _} = live(build_conn(), url <> "&selected_kind=entity&selected_id=missing")
    assert has_element?(missing, "#unavailable-target[role='alert']")
    refute has_element?(missing, "#semantic-stage")
  end

  test "catalog rejects forged revisions and symlinked snapshots", %{snapshot: snapshot} do
    directory =
      Path.join(System.tmp_dir!(), "bc_revision_denial_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    other = %{snapshot | "project_id" => "other:project"}
    other = Map.put(other, "snapshot_id", Validator.fingerprint(other))
    assert :ok = Validator.validate(other)
    assert :ok = Store.write(other, Path.join(directory, other["snapshot_id"] <> ".json"))
    prior = Application.get_env(:beamcompass_web, :navigator_catalog_dir)
    Application.put_env(:beamcompass_web, :navigator_catalog_dir, directory)

    on_exit(fn ->
      if prior do
        Application.put_env(:beamcompass_web, :navigator_catalog_dir, prior)
      else
        Application.delete_env(:beamcompass_web, :navigator_catalog_dir)
      end

      File.rm_rf(directory)
    end)

    assert {:error, :revision_unavailable} =
             NavigatorSource.select(snapshot, %{"snapshot" => other["snapshot_id"]})

    assert {:error, :revision_unavailable} =
             NavigatorSource.select(snapshot, %{"snapshot" => "../invalid"})

    assert {:error, :revision_unavailable} =
             NavigatorSource.select(snapshot, %{"snapshot" => String.duplicate("a", 64)})

    assert length(NavigatorSource.revisions(snapshot)) == 1
    link = Path.join(directory, "snapshot-symlink.json")
    assert :ok = File.ln_s(Path.join(directory, other["snapshot_id"] <> ".json"), link)
    assert {:error, :invalid_snapshot} = NavigatorSource.read(link)
  end

  test "snapshot loader rejects missing and corrupt version instead of falling back", %{
    path: path
  } do
    assert {:ok, _} = NavigatorSource.read(path)
    File.write!(path, ~s({"schema_version":3,"format":"beamcompass.snapshot"}))
    assert {:error, :invalid_snapshot} = NavigatorSource.read(path)
    assert {:error, :snapshot_not_found} = NavigatorSource.read(path <> ".missing")
  end
end
