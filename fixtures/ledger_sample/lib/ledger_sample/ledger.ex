defmodule LedgerSample.Ledger do
  @moduledoc "Pure authorization reducer that describes effects as data."

  def step(%{status: :new} = state, {:authorize, reference}) do
    new_state = Map.put(state, :status, :pending)
    {:ok, new_state, [{:dispatch, {:authorize_remote, reference}}]}
  end

  def step(%{status: :pending} = state, {:approved, reference}) do
    {:ok, Map.put(state, :status, :approved), [{:emit, {:approved, reference}}]}
  end

  def step(state, _event), do: {:error, :invalid_transition, state}
end
