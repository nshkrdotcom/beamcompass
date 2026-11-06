defmodule BeamCompass.Behavior.Entity do
  @moduledoc "Typed source-backed v2 entity; a syntactic site is not an execution guarantee."
  @enforce_keys [:id, :kind, :label, :semantic_key, :epistemic_status, :evidence_ids, :limitations]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          kind: String.t(),
          label: String.t(),
          semantic_key: String.t() | nil,
          epistemic_status: String.t(),
          evidence_ids: [String.t()],
          limitations: [String.t()]
        }
end
