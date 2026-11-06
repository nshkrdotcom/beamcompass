defmodule LedgerSample.EffectExecutor do
  @moduledoc "Only the executor performs an environmental effect."

  def execute({:dispatch, {:authorize_remote, reference}}) do
    IO.puts("fixture effect for #{reference}")
  end

  def execute({:emit, event}), do: send(self(), event)
end
