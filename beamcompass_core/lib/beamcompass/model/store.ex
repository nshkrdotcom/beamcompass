defmodule BeamCompass.Model.Store do
  @moduledoc "Persists immutable portable snapshot files without executing target code."

  alias BeamCompass.Model.Codec

  @spec write(BeamCompass.Model.Snapshot.t(), String.t()) :: :ok | {:error, term()}
  def write(snapshot, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Codec.encode(snapshot) <> "\n") do
      :ok
    end
  end

  @spec read(String.t()) :: {:ok, BeamCompass.Model.Snapshot.t()} | {:error, term()}
  def read(path) do
    with {:ok, content} <- File.read(path) do
      Codec.decode(content)
    end
  end
end
