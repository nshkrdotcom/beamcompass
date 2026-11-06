defmodule BeamCompass.Model.Codec do
  @moduledoc "Versioned portable snapshot encoding and decoding."

  alias BeamCompass.Model.{Fact, Snapshot}
  alias BeamCompass.Json

  @spec export(Snapshot.t()) :: map()
  def export(%Snapshot{} = snapshot) do
    %{
      "schema_version" => snapshot.schema_version,
      "id" => snapshot.id,
      "projects" => snapshot.projects,
      "facts" => Enum.map(snapshot.facts, &fact_to_map/1),
      "capsules" => snapshot.capsules,
      "issues" => snapshot.issues
    }
  end

  @spec encode(Snapshot.t()) :: binary()
  def encode(snapshot), do: snapshot |> export() |> Json.encode()

  @spec decode(binary()) :: {:ok, Snapshot.t()} | {:error, term()}
  def decode(content) do
    with {:ok, %{"schema_version" => 1} = data} <- JSON.decode(content) do
      {:ok,
       %Snapshot{
         schema_version: 1,
         id: data["id"],
         projects: data["projects"],
         facts: Enum.map(data["facts"], &map_to_fact/1),
         capsules: data["capsules"],
         issues: data["issues"]
       }}
    else
      {:ok, _} -> {:error, :unsupported_snapshot_version}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fact_to_map(%Fact{} = fact) do
    %{
      "id" => fact.id,
      "kind" => Atom.to_string(fact.kind),
      "subject" => fact.subject,
      "object" => fact.object,
      "status" => Atom.to_string(fact.status),
      "anchor" => fact.anchor,
      "details" => fact.details
    }
  end

  defp map_to_fact(data) do
    # The encoder emits only vocabulary members. Never create arbitrary atoms from input.
    %Fact{
      id: data["id"],
      kind: decode_kind(data["kind"]),
      subject: data["subject"],
      object: data["object"],
      status: decode_status(data["status"]),
      anchor: data["anchor"],
      details: data["details"]
    }
  end

  for kind <- [:module, :role, :function, :handler, :call, :effect_site, :intent_candidate, :message_send, :unresolved] do
    defp decode_kind(unquote(Atom.to_string(kind))), do: unquote(kind)
  end

  for status <- [:source, :proposed, :unresolved] do
    defp decode_status(unquote(Atom.to_string(status))), do: unquote(status)
  end
end
