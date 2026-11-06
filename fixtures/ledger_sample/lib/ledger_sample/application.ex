defmodule LedgerSample.Application do
  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([LedgerSample.Server], strategy: :one_for_one, name: LedgerSample.Supervisor)
  end
end
