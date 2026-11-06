defmodule BeamCompass.Behavior.Evidence do
  @moduledoc "Source-only evidence with an anchored producer and optional derivation parents."
  @enforce_keys [:id, :provider_id, :mode, :anchor, :basis, :input_evidence_ids]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          provider_id: String.t(),
          mode: String.t(),
          anchor: map(),
          basis: String.t(),
          input_evidence_ids: [String.t()]
        }
end
