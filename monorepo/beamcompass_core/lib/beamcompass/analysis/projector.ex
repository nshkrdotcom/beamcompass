defmodule BeamCompass.Analysis.Projector do
  @moduledoc """
  Budgeted source-grounded view projection. This first implementation deliberately
  reports omissions and cannot promise transitive effect or process completeness.
  """

  alias BeamCompass.Model.Snapshot

  @lenses [:behavior, :effects, :state]

  @spec project(Snapshot.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def project(%Snapshot{} = snapshot, options \\ []) do
    lens = Keyword.get(options, :lens, :behavior)
    budget = Keyword.get(options, :budget, 30)

    cond do
      lens not in @lenses -> {:error, {:unsupported_lens, lens}}
      not is_integer(budget) or budget < 1 -> {:error, :invalid_budget}
      true -> {:ok, render(snapshot, lens, budget)}
    end
  end

  defp render(snapshot, lens, budget) do
    selected =
      case lens do
        :behavior ->
          Enum.map(snapshot.capsules, &capsule_node/1)

        :effects ->
          snapshot.facts
          |> Enum.filter(&(&1.kind in [:effect_site, :intent_candidate]))
          |> Enum.map(&fact_node/1)

        :state ->
          snapshot.facts |> Enum.filter(&(&1.kind in [:role, :handler])) |> Enum.map(&fact_node/1)
      end
      |> Enum.sort_by(& &1["id"])

    visible = Enum.take(selected, budget)
    omitted = length(selected) - length(visible)

    %{
      "schema_version" => 1,
      "snapshot_id" => snapshot.id,
      "lens" => Atom.to_string(lens),
      "nodes" => visible,
      "edges" => [],
      "receipts" => [
        %{
          "kind" => "node_budget",
          "total" => length(selected),
          "visible" => length(visible),
          "omitted" => omitted
        }
      ],
      "unresolved_count" => Enum.count(snapshot.facts, &(&1.kind == :unresolved)),
      "limitations" => [
        "local_clause_only",
        "unresolved_dispatch_visible_in_inventory",
        "not_a_complete_runtime_model"
      ]
    }
  end

  defp capsule_node(capsule) do
    %{
      "id" => capsule["id"],
      "kind" => "capsule",
      "title" => capsule["title"],
      "subtitle" => capsule["trigger"],
      "source_fact_id" => capsule["source_fact_id"],
      "evidence_ids" => capsule["evidence_ids"],
      "effect_count" => length(capsule["effect_fact_ids"]),
      "intent_count" => length(capsule["intent_fact_ids"]),
      "status" => capsule["status"]
    }
  end

  defp fact_node(fact) do
    %{
      "id" => fact.id,
      "kind" => Atom.to_string(fact.kind),
      "title" => fact.subject,
      "subtitle" => fact.object,
      "source_fact_id" => fact.id,
      "evidence_ids" => [fact.id],
      "status" => Atom.to_string(fact.status)
    }
  end
end
