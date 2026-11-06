defmodule BeamCompass.Behavior.Store do
  @moduledoc "Atomic canonical v2 output; failed validation or write does not replace an existing file."

  alias BeamCompass.Behavior.Validator
  alias BeamCompass.Json

  @spec write(map(), String.t()) :: :ok | {:error, term()}
  def write(snapshot, path) when is_binary(path) do
    with :ok <- Validator.validate(snapshot) do
      write_json(snapshot, path)
    end
  end

  @spec write_json(map(), String.t()) :: :ok | {:error, term()}
  def write_json(data, path) when is_binary(path) do
    directory = Path.dirname(path)

    with :ok <- File.mkdir_p(directory) do
      temporary =
        Path.join(directory, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

      try do
        with :ok <-
               File.write(temporary, Json.encode(data) <> "\n", [:write, :binary, :exclusive]) do
          File.rename(temporary, path)
        end
      after
        File.rm(temporary)
      end
    end
  end
end
