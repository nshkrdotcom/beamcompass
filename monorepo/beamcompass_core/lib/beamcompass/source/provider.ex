defmodule BeamCompass.Source.Provider do
  @moduledoc """
  Core-only input adapter contract: source bytes in, syntactic facts or errors out.

  No adapter may load a target's Mix configuration, expand target macros,
  compile its modules, or emit non-source evidence in P02.
  """
  @callback scan(binary(), String.t()) ::
              {:ok, [BeamCompass.Model.Fact.t()]} | {:error, String.t()}
  @callback identity() :: map()
end
