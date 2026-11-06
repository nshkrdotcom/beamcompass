defmodule BeamCompass.Source.Discovery do
  @moduledoc "Discovers standalone and Poncho Mix projects without evaluating mix.exs."

  @spec discover(String.t()) :: {:ok, list(map())} | {:error, String.t()}
  def discover(path) do
    root = Path.expand(path)

    cond do
      not File.dir?(root) ->
        {:error, "directory does not exist: #{root}"}

      File.regular?(Path.join(root, "mix.exs")) ->
        {:ok, [project(root, root)]}

      true ->
        roots =
          root
          |> Path.join("*/mix.exs")
          |> Path.wildcard()
          |> Enum.map(&Path.dirname/1)
          |> Enum.reject(&symlink?/1)
          |> Enum.sort()

        case roots do
          [] -> {:error, "no Mix projects found beneath #{root}"}
          _ -> {:ok, Enum.map(roots, &project(&1, root))}
        end
    end
  end

  defp project(project_root, workspace_root) do
    paths =
      ["lib/**/*.ex", "lib/**/*.exs"]
      |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(project_root, glob)) end)
      |> Enum.uniq()
      |> Enum.filter(&(File.regular?(&1) and not symlink?(&1)))
      |> Enum.sort()

    %{
      name: Path.basename(project_root),
      path: Path.relative_to(project_root, workspace_root),
      paths: Enum.map(paths, &{&1, Path.relative_to(&1, workspace_root)})
    }
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> true
      _ -> false
    end
  end
end
