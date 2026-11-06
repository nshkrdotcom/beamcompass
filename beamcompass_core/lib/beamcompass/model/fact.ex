defmodule BeamCompass.Model.Fact do
  @moduledoc "A source-grounded assertion. A static occurrence is not a runtime guarantee."

  @enforce_keys [:id, :kind, :subject, :object, :status, :anchor]
  defstruct [:id, :kind, :subject, :object, :status, :anchor, details: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          subject: String.t(),
          object: String.t(),
          status: atom(),
          anchor: map(),
          details: map()
        }
end
