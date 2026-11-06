defmodule BeamCompass.Source.Providers.Quoted do
  @moduledoc "Nonexecuting built-in Elixir quoted AST adapter with start-only anchors."

  @behaviour BeamCompass.Source.Provider
  alias BeamCompass.Source.Scanner

  @impl true
  def scan(bytes, path), do: Scanner.scan(bytes, path)

  @impl true
  def identity do
    %{
      "id" => "provider:elixir-ast",
      "name" => "beamcompass-elixir-quoted-ast",
      "version" => "1 (Elixir #{System.version()})",
      "mode" => "source",
      "trust_context" => "in-process quoted AST parser; target code, mix.exs and macros not evaluated"
    }
  end
end
