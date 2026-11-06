defmodule BeamCompass.Analysis.Diff do
  @moduledoc "Compare source fact identities between portable snapshots."

  alias BeamCompass.Model.Snapshot

  @spec compare(Snapshot.t(), Snapshot.t()) :: map()
  def compare(%Snapshot{} = before, %Snapshot{} = later) do
    old = Map.new(before.facts, &{&1.id, &1})
    new = Map.new(later.facts, &{&1.id, &1})

    %{
      "before" => before.id,
      "after" => later.id,
      "added" =>
        new |> Map.drop(Map.keys(old)) |> Map.values() |> Enum.map(& &1.id) |> Enum.sort(),
      "removed" =>
        old |> Map.drop(Map.keys(new)) |> Map.values() |> Enum.map(& &1.id) |> Enum.sort(),
      "note" => "Compares syntactic facts, not proven runtime behavior"
    }
  end
end
