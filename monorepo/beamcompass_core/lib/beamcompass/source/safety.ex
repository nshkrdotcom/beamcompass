defmodule BeamCompass.Source.Safety do
  @moduledoc """
  Defensive ceilings for nonexecuting source inspection. These are technical input
  guards, NOT owner-approved throughput or recovery SLOs. The target is never
  loaded, expanded, compiled, or evaluated. Parsing occurs in a monitored BEAM
  worker with a bounded heap and wall-clock timeout. This is not an OS sandbox.
  """

  @max_files 2_000
  @max_file_bytes 2_097_152
  @max_total_bytes 33_554_432
  @parse_timeout_ms 3_000
  @parser_heap_words 4_000_000

  @spec limits() :: map()
  def limits do
    %{
      "max_files" => @max_files,
      "max_file_bytes" => @max_file_bytes,
      "max_total_bytes" => @max_total_bytes,
      "parse_timeout_ms" => @parse_timeout_ms,
      "parser_heap_words" => @parser_heap_words
    }
  end

  @doc "Reject unexpectedly large, sparse or symlinked source inputs before parsing."
  @spec inventory(list(map())) :: :ok | {:error, term()}
  def inventory(projects) when is_list(projects) do
    files = Enum.flat_map(projects, & &1.paths)

    cond do
      files == [] -> {:error, :empty_source_corpus}
      length(files) > @max_files -> {:error, {:source_file_limit, length(files), @max_files}}
      true -> :ok
    end
  end

  @spec read(String.t(), String.t(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def read(absolute, relative, total) when is_integer(total) and total >= 0 do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(absolute),
         :ok <- within_file_limit(relative, size),
         :ok <- within_total_limit(total + size),
         {:ok, bytes} <- File.read(absolute),
         :ok <- within_file_limit(relative, byte_size(bytes)),
         :ok <- within_total_limit(total + byte_size(bytes)) do
      {:ok, bytes, total + byte_size(bytes)}
    else
      {:ok, _} -> {:error, {:unsafe_source_type, relative}}
      {:error, reason} -> {:error, {:unsafe_source_input, relative, reason}}
    end
  end

  @spec run((() -> term()), pos_integer()) :: {:ok, term()} | {:error, term()}
  def run(fun, timeout_ms \\ @parse_timeout_ms)
      when is_function(fun, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    caller = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: @parser_heap_words, kill: true, error_logger: false})
        send(caller, {token, fun.()})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:parser_worker_failed, reason}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :parser_timeout}
    end
  end

  defp within_file_limit(_relative, size) when size <= @max_file_bytes and size >= 0,
    do: :ok

  defp within_file_limit(relative, size),
    do: {:error, {:source_file_bytes_limit, relative, size, @max_file_bytes}}

  defp within_total_limit(total) when total <= @max_total_bytes, do: :ok
  defp within_total_limit(total), do: {:error, {:source_total_bytes_limit, total, @max_total_bytes}}
end
