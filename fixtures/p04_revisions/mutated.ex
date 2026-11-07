defmodule BeamCompass.P04SourceCase do
  def reserve(state, amount) do
    updated = Map.update!(state, :reserved, fn reserved -> reserved + amount end)
    {:ok, updated, [{:emit, :reservation_confirmed}]}
  end

  def void(state, amount) do
    updated = Map.update!(state, :reserved, fn reserved -> reserved - amount end)
    {:ok, updated, []}
  end

  def executor(target, key), do: apply(target, :void, [key])
end
