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

    with :ok <- safe_parents(path),
         :ok <- safe_target(path),
         :ok <- File.mkdir_p(directory),
         :ok <- safe_parents(path),
         :ok <- safe_target(path) do
      temporary =
        Path.join(directory, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

      try do
        with :ok <-
               File.write(temporary, Json.encode(data) <> "\n", [:write, :binary, :exclusive]),
             :ok <- safe_target(path) do
          File.rename(temporary, path)
        end
      after
        File.rm(temporary)
      end
    end
  end

  @spec safe_target(String.t()) :: :ok | {:error, term()}
  def safe_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _} -> {:error, :unsafe_output_file_type}
      {:error, reason} -> {:error, reason}
    end
  end

  # Detect pre-existing directory symlinks. This is filesystem hardening, not
  # a defense against an adversarial concurrent OS path-swap (no OS sandbox).
  @spec safe_parents(String.t()) :: :ok | {:error, term()}
  def safe_parents(path) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn part, {:ok, prefix} ->
      next = Path.join(prefix, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :unsafe_parent_symlink}}
        {:ok, %File.Stat{type: :directory}} -> {:cont, {:ok, next}}
        {:error, :enoent} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
        {:ok, _} -> {:halt, {:error, :unsafe_parent_type}}
      end
    end)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
