defmodule BeamCompass.Behavior.Archive do
  @moduledoc """
  Content-addressed persistent v2 snapshot bundles. This is a NEW format;
  `BeamCompass.Model.Codec` and the v1 `Store` are deliberately untouched.

  An archive contains the exact v2 snapshot plus the enumerated source byte
  identities supplied by the fresh source scan, not source bytes or executed
  code. A legacy v1 file cannot be promoted to v2 without a new source scan.
  """

  alias BeamCompass.Behavior.{Store, Validator}
  alias BeamCompass.Json
  alias BeamCompass.Source.Provenance

  @hex ~r/\A[0-9a-f]{64}\z/
  @max_archive_bytes 64 * 1024 * 1024
  @bundle_keys ~w(format schema_version content_id snapshot_schema_version snapshot inputs)

  @spec build(map(), list(map())) :: {:ok, map()} | {:error, term()}
  def build(snapshot, inputs) when is_list(inputs) do
    with :ok <- Validator.validate(snapshot),
         :ok <- validate_inputs(snapshot, inputs) do
      body = %{
        "format" => "beamcompass.persistent-snapshot",
        "schema_version" => 1,
        "snapshot_schema_version" => 2,
        "snapshot" => snapshot,
        "inputs" => inputs
      }

      {:ok, Map.put(body, "content_id", Provenance.sha256(Json.encode(body)))}
    end
  end

  def build(_, _), do: {:error, :invalid_archive_inputs}

  @doc "Persist once under an exact digest-derived name; never replace a conflicting object."
  @spec put(map(), list(map()), String.t()) :: {:ok, map()} | {:error, term()}
  def put(snapshot, inputs, root) when is_binary(root) do
    with {:ok, bundle} <- build(snapshot, inputs),
         {:ok, path} <- location(root, bundle["content_id"]),
         :ok <- Store.safe_parents(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- Store.safe_parents(path),
         :ok <- write_once(bundle, path) do
      {:ok, %{"content_id" => bundle["content_id"], "path" => path}}
    end
  end

  def put(_, _, _), do: {:error, :invalid_archive_root}

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(root, content_id) do
    with {:ok, path} <- location(root, content_id),
         :ok <- Store.safe_parents(path),
         {:ok, bytes} <- safe_read(path),
         {:ok, bundle} <- JSON.decode(bytes),
         :ok <- validate(bundle),
         true <- bytes == Json.encode(bundle) <> "\n",
         true <- bundle["content_id"] == content_id do
      {:ok, bundle}
    else
      false -> {:error, :noncanonical_archive_or_wrong_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Rehydrate only the exact validated v2 source graph; never upgrade a v1 value."
  @spec rehydrate(map()) :: {:ok, map()} | {:error, term()}
  def rehydrate(bundle) do
    with :ok <- validate(bundle), do: {:ok, bundle["snapshot"]}
  end

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(bundle) when is_map(bundle) do
    cond do
      Enum.sort(Map.keys(bundle)) != Enum.sort(@bundle_keys) ->
        {:error, :invalid_archive_envelope}

      bundle["format"] != "beamcompass.persistent-snapshot" or
        bundle["schema_version"] != 1 or bundle["snapshot_schema_version"] != 2 ->
        {:error, :unsupported_archive_version}

      not is_binary(bundle["content_id"]) or
          not Regex.match?(@hex, bundle["content_id"]) ->
        {:error, :invalid_archive_identity}

      true ->
        with :ok <- Validator.validate(bundle["snapshot"]),
             :ok <- validate_inputs(bundle["snapshot"], bundle["inputs"]),
             true <-
               bundle["content_id"] ==
                 Provenance.sha256(Json.encode(Map.delete(bundle, "content_id"))) do
          :ok
        else
          false -> {:error, :archive_hash_mismatch}
          error -> error
        end
    end
  end

  def validate(_), do: {:error, :invalid_archive_envelope}

  # Disallow version migration by rebranding old facts as newer evidence.
  @spec migrate(term(), integer()) ::
          {:error, :source_reextraction_required | :unsupported_archive_version}
  def migrate(%BeamCompass.Model.Snapshot{}, 2), do: {:error, :source_reextraction_required}
  def migrate(_, _), do: {:error, :unsupported_archive_version}

  defp write_once(bundle, path) do
    # A hard link creates the immutable object name only if it does not exist.
    # A regular rename could silently overwrite another concurrent writer.
    bytes = Json.encode(bundle) <> "\n"
    temp = path <> "." <> Integer.to_string(System.unique_integer([:positive])) <> ".tmp"

    try do
      with :ok <- File.write(temp, bytes, [:binary, :exclusive]) do
        case File.ln(temp, path) do
          :ok ->
            :ok

          {:error, :eexist} ->
            case safe_read(path) do
              {:ok, ^bytes} -> :ok
              {:ok, _other} -> {:error, :archive_conflict}
              error -> error
            end

          error ->
            error
        end
      end
    after
      File.rm(temp)
    end
  end

  defp safe_read(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= @max_archive_bytes,
         {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @max_archive_bytes do
      {:ok, bytes}
    else
      false -> {:error, :archive_size_limit}
      {:ok, _} -> {:error, :unsafe_archive_file_type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp location(root, id) when is_binary(root) and is_binary(id) do
    if Regex.match?(@hex, id) do
      {:ok, Path.join([root, "v1", binary_part(id, 0, 2), id <> ".json"])}
    else
      {:error, :invalid_archive_identity}
    end
  end

  defp location(_, _), do: {:error, :invalid_archive_identity}

  defp validate_inputs(snapshot, inputs) when is_list(inputs) and is_map(snapshot) do
    valid =
      inputs != [] and
        Enum.all?(inputs, fn input ->
          is_map(input) and Enum.sort(Map.keys(input)) == ~w(path sha256) and
            valid_path?(input["path"]) and is_binary(input["sha256"]) and
            Regex.match?(@hex, input["sha256"])
        end)

    if valid do
      paths = Enum.map(inputs, & &1["path"])
      by_path = Map.new(inputs, &{&1["path"], &1["sha256"]})

      with true <- paths == Enum.sort(Enum.uniq(paths)),
           true <-
             snapshot["manifest"]["source_digest"] ==
               Provenance.sha256(Json.encode(inputs)),
           true <-
             Enum.all?(snapshot["evidence"], &matching_source?(&1, by_path)) do
        :ok
      else
        false -> {:error, :archive_source_mismatch}
      end
    else
      {:error, :invalid_archive_inputs}
    end
  end

  defp validate_inputs(_, _), do: {:error, :invalid_archive_inputs}

  defp matching_source?(evidence, by_path) do
    evidence["anchor"]["source_sha256"] == by_path[evidence["anchor"]["path"]]
  end

  defp valid_path?(path) when is_binary(path) do
    path != "" and not String.starts_with?(path, "/") and
      not String.contains?(path, ["\\", ":", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp valid_path?(_), do: false
end
