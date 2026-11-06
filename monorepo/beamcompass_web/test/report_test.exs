defmodule BeamCompassWeb.ReportTest do
  use ExUnit.Case, async: true

  alias BeamCompass.Model.{Fact, Snapshot}
  alias BeamCompassWeb.Report

  @fixture Path.expand("../../fixtures/ledger_sample", __DIR__)

  test "renders all three supported views and a truthful limitations notice" do
    assert {:ok, snapshot} = BeamCompass.scan(@fixture)
    html = Report.render(snapshot)

    assert html =~ "Behavior lens"
    assert html =~ "Effects lens"
    assert html =~ "State lens"
    assert html =~ "not proof of runtime reachability"
    assert html =~ "Evidence:"
  end

  test "escapes untrusted source strings instead of embedding scripts" do
    fact = %Fact{
      id: "source-id",
      kind: :effect_site,
      subject: "<script>alert(1)</script>",
      object: "&\"",
      status: :source,
      anchor: %{"path" => "lib/test.ex", "line" => 1},
      details: %{}
    }

    snapshot = %Snapshot{
      id: "example",
      projects: [],
      facts: [fact],
      capsules: [],
      issues: []
    }

    html = Report.render(snapshot)
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "&amp;&quot;"
    refute html =~ "<script>alert(1)</script>"
  end
end
