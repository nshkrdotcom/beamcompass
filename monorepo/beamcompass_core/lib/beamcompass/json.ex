defmodule BeamCompass.Json do
  @moduledoc "Deterministic JSON serialization without third-party runtime dependencies."

  @spec encode(term()) :: String.t()
  def encode(%_{} = struct), do: struct |> Map.from_struct() |> encode()

  def encode(map) when is_map(map) do
    entries =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> JSON.encode!(key) <> ":" <> encode(value) end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  def encode(items) when is_list(items), do: "[" <> Enum.map_join(items, ",", &encode/1) <> "]"
  def encode(value), do: JSON.encode!(value)
end
