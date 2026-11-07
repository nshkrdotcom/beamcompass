defmodule BeamCompass.Artifact.Migration do
  @moduledoc """
  Versioned loss-accounted transport of *unchanged* supported v1 and v2 payloads.
  This does NOT turn v1 syntactic facts into v2 provenance or reinterpret v2 as
  v1 facts. Cross-schema semantic promotion requires trusted re-extraction and
  is refused with actionable loss information. Exact carried payloads rehydrate.
  """

  alias BeamCompass.Behavior.Validator
  alias BeamCompass.Json
  alias BeamCompass.Model.{Codec, Snapshot}
  alias BeamCompass.Source.Provenance

  @format "beamcompass.compatibility-envelope"
  @version 1
  @types ["v1_snapshot", "v2_snapshot"]

  @spec wrap(Snapshot.t() | map()) :: {:ok, map()} | {:error, term()}
  def wrap(%Snapshot{} = snapshot), do: wrap_payload("v1_snapshot", Codec.export(snapshot))

  def wrap(%{"schema_version" => 2} = snapshot),
    do: wrap_payload("v2_snapshot", snapshot)

  def wrap(_), do: {:error, :unsupported_artifact_version}

  @spec rehydrate(map()) :: {:ok, Snapshot.t() | map()} | {:error, term()}
  def rehydrate(%{"format" => @format} = envelope) do
    with :ok <- validate(envelope) do
      case envelope["source_format"] do
        "v1_snapshot" -> Codec.decode(Json.encode(envelope["payload"]))
        "v2_snapshot" -> {:ok, envelope["payload"]}
      end
    end
  end

  def rehydrate(_), do: {:error, :unsupported_compatibility_envelope}

  @spec validate(map()) :: :ok | {:error, atom()}
  def validate(envelope) when is_map(envelope) do
    expected = ~w(format schema_version source_format payload loss migration_status content_sha256)

    cond do
      Enum.sort(Map.keys(envelope)) != Enum.sort(expected) ->
        {:error, :invalid_compatibility_envelope}

      envelope["format"] != @format or envelope["schema_version"] != @version or
        envelope["source_format"] not in @types ->
        {:error, :unsupported_compatibility_version}

      envelope["migration_status"] != "lossless_transport_only" or envelope["loss"] != [] ->
        {:error, :unacknowledged_migration_loss}

      envelope["content_sha256"] != digest(envelope) ->
        {:error, :compatibility_hash_mismatch}

      true ->
        validate_payload(envelope["source_format"], envelope["payload"])
    end
  end

  def validate(_), do: {:error, :invalid_compatibility_envelope}

  @doc "Explicitly refuse an information-losing cross-schema semantic rewrite."
  @spec promote(term(), pos_integer()) :: {:error, map()}
  def promote(%Snapshot{}, 2) do
    {:error,
     %{
       "reason" => "source_reextraction_required",
       "loss" => ["v2_source_hashes", "v2_provider_identity", "v2_typed_lineage"],
       "action" => "Re-scan original source with export_source/2 and new project_id; never claim recovered evidence"
     }}
  end

  def promote(%{"schema_version" => 2}, 1) do
    {:error,
     %{
       "reason" => "semantic_downgrade_unsupported",
       "loss" => ["v2_relation_resolution", "v2_evidence_lineage", "v2_exact_snapshot_refs"],
       "action" => "Keep the v2 snapshot; use an independently versioned v2 consumer"
     }}
  end

  def promote(_, _),
    do: {:error, %{"reason" => "unsupported_artifact_version", "loss" => ["unknown"],
                   "action" => "Read the documented supported version matrix"}}

  defp wrap_payload(type, payload) do
    with :ok <- validate_payload(type, payload) do
      body = %{
        "format" => @format,
        "schema_version" => @version,
        "source_format" => type,
        "payload" => payload,
        "loss" => [],
        "migration_status" => "lossless_transport_only"
      }

      {:ok, Map.put(body, "content_sha256", digest(body))}
    end
  end

  defp validate_payload("v1_snapshot", payload) do
    case Codec.decode(Json.encode(payload)) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :invalid_legacy_payload}
    end
  end

  defp validate_payload("v2_snapshot", payload), do: Validator.validate(payload)

  defp digest(body), do: Provenance.sha256(Json.encode(Map.delete(body, "content_sha256")))
end
