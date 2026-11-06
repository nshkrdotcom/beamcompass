defmodule BeamCompass.Behavior.Relation do
  @moduledoc "Typed v2 relation with separate target resolution and epistemic status."
  @enforce_keys [
    :id, :kind, :source_id, :target_id, :resolution, :epistemic_status, :evidence_ids,
    :rationale
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          kind: String.t(),
          source_id: String.t(),
          target_id: String.t() | nil,
          resolution: String.t(),
          epistemic_status: String.t(),
          evidence_ids: [String.t()],
          rationale: String.t()
        }
end
