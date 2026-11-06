defmodule BeamCompass.Id do
  @moduledoc "Stable identities for semantic artifacts independent of source line numbers."

  @spec for_parts([term()]) :: String.t()
  def for_parts(parts) do
    parts
    |> Enum.map_join("\u0000", &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
