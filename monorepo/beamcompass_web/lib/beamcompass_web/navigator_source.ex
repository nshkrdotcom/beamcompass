defmodule BeamCompassWeb.NavigatorSource do
  @moduledoc """
  Loads caller-configured **exported** v2 source snapshots only. The optional
  revision catalog is a read-only directory of files named by their exact
  snapshot IDs; neither this module nor its callers execute inspected sources.
  """

  alias BeamCompass.Behavior.Validator

  @max_bytes 16 * 1024 * 1024
  @max_revisions 64
  @snapshot_id ~r/\A[0-9a-f]{64}\z/

  @spec load() :: {:ok, map()} | {:error, atom()}
  def load do
    case Application.get_env(:beamcompass_web, :navigator_snapshot_path) do
      path when is_binary(path) and byte_size(path) > 0 -> read(path)
      _ -> {:error, :snapshot_not_configured}
    end
  end

  @doc "Only a caller-configured regular JSON artifact is read; symlinks are refused."
  @spec read(String.t()) :: {:ok, map()} | {:error, atom()}
  def read(path) when is_binary(path) do
    with {:ok, stat} <- File.lstat(path),
         :ok <- ensure_size(stat),
         {:ok, bytes} <- File.read(path),
         {:ok, snapshot} <- JSON.decode(bytes),
         :ok <- Validator.validate(snapshot) do
      {:ok, snapshot}
    else
      {:error, :enoent} -> {:error, :snapshot_not_found}
      {:error, _} -> {:error, :invalid_snapshot}
    end
  end

  def read(_), do: {:error, :invalid_snapshot_path}

  @doc """
  Resolve an explicitly pinned revision from an opt-in, trusted artifact catalog.
  Never substitute by name, revision order, project, label or semantic key.
  The default artifact remains the only accepted revision without a catalog.
  """
  @spec select(map(), map()) :: {:ok, map()} | {:error, :revision_unavailable}
  def select(base, params) when is_map(base) and is_map(params) do
    requested = Map.get(params, "snapshot", base["snapshot_id"])

    cond do
      requested == base["snapshot_id"] ->
        {:ok, base}

      not is_binary(requested) or not Regex.match?(@snapshot_id, requested) ->
        {:error, :revision_unavailable}

      true ->
        project_id = base["project_id"]

        case catalog_path(requested) do
          {:ok, path} ->
            case read(path) do
              {:ok, %{"snapshot_id" => ^requested, "project_id" => ^project_id} = revision} ->
                {:ok, revision}

              _ ->
                {:error, :revision_unavailable}
            end

          _ ->
            {:error, :revision_unavailable}
        end
    end
  end

  def select(_, _), do: {:error, :revision_unavailable}

  @doc "List only validated revisions belonging to the currently opened project."
  @spec revisions(map()) :: [map()]
  def revisions(%{"snapshot_id" => id, "project_id" => project} = base) do
    catalog =
      case Application.get_env(:beamcompass_web, :navigator_catalog_dir) do
        path when is_binary(path) and byte_size(path) > 0 ->
          case File.ls(path) do
            {:ok, names} ->
              names
              |> Enum.filter(&String.ends_with?(&1, ".json"))
              |> Enum.filter(&(Regex.match?(@snapshot_id, String.trim_trailing(&1, ".json"))))
              |> Enum.sort()
              |> Enum.take(@max_revisions)
              |> Enum.flat_map(fn name ->
                revision_id = String.trim_trailing(name, ".json")

                case read(Path.join(path, name)) do
                  {:ok, %{"snapshot_id" => ^revision_id, "project_id" => ^project} = value} ->
                    [value]

                  _ ->
                    []
                end
              end)

            _ ->
              []
          end

        _ ->
          []
      end

    [base | catalog]
    |> Enum.uniq_by(& &1["snapshot_id"])
    |> Enum.sort_by(& &1["snapshot_id"])
    |> Enum.map(&%{"snapshot_id" => &1["snapshot_id"], "current" => &1["snapshot_id"] == id})
  end

  defp catalog_path(id) do
    case Application.get_env(:beamcompass_web, :navigator_catalog_dir) do
      directory when is_binary(directory) and byte_size(directory) > 0 ->
        {:ok, Path.join(directory, id <> ".json")}

      _ ->
        {:error, :revision_unavailable}
    end
  end

  defp ensure_size(%File.Stat{type: :regular, size: size}) when size in 1..@max_bytes,
    do: :ok

  defp ensure_size(_), do: {:error, :snapshot_unavailable_or_too_large}
end
