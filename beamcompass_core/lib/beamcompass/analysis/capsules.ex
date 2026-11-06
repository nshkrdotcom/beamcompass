defmodule BeamCompass.Analysis.Capsules do
  @moduledoc "Constructs provisional behavior capsules from source-observed handler clauses."

  alias BeamCompass.Id

  @spec build(list(BeamCompass.Model.Fact.t())) :: list(map())
  def build(facts) do
    facts
    |> Enum.filter(&(&1.kind == :handler))
    |> Enum.map(fn handler ->
      related =
        facts
        |> Enum.filter(&(&1.subject == handler.subject and &1.kind in [:call, :effect_site, :intent_candidate, :message_send, :unresolved]))
        |> Enum.sort_by(& &1.id)

      %{
        "id" => "capsule-" <> String.slice(Id.for_parts([handler.id]), 0, 20),
        "title" => handler.subject,
        "trigger" => handler.object,
        "source_fact_id" => handler.id,
        "evidence_ids" => [handler.id | Enum.map(related, & &1.id)],
        "effect_fact_ids" => Enum.filter(related, &(&1.kind == :effect_site)) |> Enum.map(& &1.id),
        "intent_fact_ids" => Enum.filter(related, &(&1.kind == :intent_candidate)) |> Enum.map(& &1.id),
        "unresolved_fact_ids" => Enum.filter(related, &(&1.kind == :unresolved)) |> Enum.map(& &1.id),
        "coverage" => "local_clause_only",
        "status" => "provisional"
      }
    end)
    |> Enum.sort_by(& &1["id"])
  end
end
