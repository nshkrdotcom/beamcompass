defmodule BeamCompass.Model.Store do
  @moduledoc """
  Atomically persist the legacy v1 wire format. Bad or interrupted writes do
  not truncate an older snapshot; v1 readers and canonical encoding are retained.
  """

  alias BeamCompass.Behavior.Store, as: AtomicStore
  alias BeamCompass.Model.Codec

  @max_read_bytes 64 * 1024 * 1024

  @spec write(BeamCompass.Model.Snapshot.t(), String.t()) :: :ok | {:error, term()}
  def write(snapshot, path) when is_binary(path) do
    AtomicStore.write_json(Codec.export(snapshot), path)
  end

  @spec read(String.t()) :: {:ok, BeamCompass.Model.Snapshot.t()} | {:error, term()}
  def read(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= @max_read_bytes,
         {:ok, content} <- File.read(path),
         true <- byte_size(content) <= @max_read_bytes do
      Codec.decode(content)
    else
      false -> {:error, :snapshot_size_limit}
      {:ok, _} -> {:error, :unsafe_snapshot_file_type}
      {:error, reason} -> {:error, reason}
    end
  end
end
