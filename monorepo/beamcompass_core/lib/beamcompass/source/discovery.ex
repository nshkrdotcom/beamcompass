defmodule BeamCompass.Source.Discovery do
  @moduledoc "Discovers standalone, Poncho and monorepo Poncho Mix projects without evaluating mix.exs."

  @spec discover(String.t()) :: {:ok, list(map())} | {:error, String.t()}
  def discover(path) do
    root = Path.expand(path)

    cond do
      not File.dir?(root) ->
        {:error, "directory does not exist: #{root}"}

      symlink_path?(root, "/") ->
        {:error, "workspace root or its ancestors must not be symlinks"}

      File.regular?(Path.join(root, "mix.exs")) ->
        safe_projects([root], root)

      true ->
        # Only two documented depths. No recursive traversal of arbitrary apps,
        # and no evaluation or expansion of a discovered mix.exs.
        roots =
          ["*/mix.exs", "monorepo/*/mix.exs"]
          |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
          |> Enum.map(&Path.dirname/1)
          |> Enum.reject(&symlink_path?(&1, root))
          |> Enum.uniq()
          |> Enum.sort()

        case roots do
          [] -> {:error, "no Mix projects found beneath #{root}"}
          _ -> safe_projects(roots, root)
        end
    end
  end

  defp safe_projects(roots, workspace_root) do
    projects = Enum.map(roots, &project(&1, workspace_root))

    if Enum.any?(projects, &(not Enum.empty?(&1.unsafe_paths))) do
      {:error, "unsafe source path or symlink in Mix project; refusing incomplete scan"}
    else
      {:ok, Enum.map(projects, &Map.delete(&1, :unsafe_paths))}
    end
  end

  defp project(project_root, workspace_root) do
    candidates =
      ["lib/**/*.ex", "lib/**/*.exs"]
      |> Enum.flat_map(&Path.wildcard(Path.join(project_root, &1)))
      |> Enum.uniq()
      |> Enum.sort()

    unsafe_paths =
      [Path.join(project_root, "mix.exs") | candidates]
      |> Enum.filter(&symlink_path?(&1, workspace_root))

    paths = Enum.filter(candidates, &File.regular?/1)

    %{
      name: Path.basename(project_root),
      path: Path.relative_to(project_root, workspace_root),
      paths: Enum.map(paths, &{&1, Path.relative_to(&1, workspace_root)}),
      unsafe_paths: unsafe_paths
    }
  end

  defp symlink_path?(path, root) do
    relative = Path.relative_to(path, root)

    relative
    |> Path.split()
    |> Enum.reduce({root, false}, fn part, {prefix, found?} ->
      next = Path.join(prefix, part)
      {next, found? or symlink?(next)}
    end)
    |> elem(1)
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end
end
