defmodule LedgerSample.Server do
  @moduledoc "Process shell using the pure reducer."
  use GenServer

  alias LedgerSample.Ledger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{status: :new}, name: __MODULE__)
  def authorize(reference), do: GenServer.call(__MODULE__, {:authorize, reference})

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:authorize, reference}, _from, state) do
    {:ok, updated, effects} = Ledger.step(state, {:authorize, reference})
    send(self(), {:run_effects, effects})
    {:reply, :accepted, updated}
  end

  @impl GenServer
  def handle_info({:run_effects, effects}, state) do
    Enum.each(effects, &LedgerSample.EffectExecutor.execute/1)
    {:noreply, state}
  end
end
