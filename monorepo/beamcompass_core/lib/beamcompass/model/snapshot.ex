defmodule BeamCompass.Model.Snapshot do
  @moduledoc "Deterministic source snapshot with non-executing extraction results."

  @enforce_keys [:id, :projects, :facts, :capsules, :issues]
  defstruct [:id, :projects, :facts, :capsules, :issues, schema_version: 1]

  @type t :: %__MODULE__{
          id: String.t(),
          projects: list(map()),
          facts: list(BeamCompass.Model.Fact.t()),
          capsules: list(map()),
          issues: list(map()),
          schema_version: pos_integer()
        }
end
