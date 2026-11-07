defmodule BeamCompass.Release.Policy do
  @moduledoc """
  A fail-closed BeamCompass **release** gate, not Grand approval/assurance logic.
  Owners must provide measured and explicitly approved numeric scale/recovery
  limits. Source scanner defensive ceilings are not release SLO approvals.
  """

  alias BeamCompass.Json
  alias BeamCompass.Source.Provenance

  @metrics ~w(wall_ms rss_bytes source_files recovery_ms)
  @thresholds ~w(max_wall_ms max_rss_bytes max_source_files max_recovery_ms)

  @spec fingerprint(map()) :: String.t()
  def fingerprint(data) when is_map(data), do: Provenance.sha256(Json.encode(data))

  @spec evaluate(map(), map() | nil, list(map())) :: {:ok, map()} | {:error, map()}
  def evaluate(measured, approval, findings) do
    errors =
      []
      |> missing_observations(measured)
      |> missing_approval(approval)
      |> high_severity(findings)
      |> breached_limits(measured, approval)
      |> Enum.uniq()
      |> Enum.sort()

    if errors == [] do
      {:ok, %{"release_eligible" => true, "measurement_fingerprint" => fingerprint(measured)}}
    else
      {:error, %{"release_eligible" => false, "blockers" => errors}}
    end
  end

  defp missing_observations(errors, measured) when is_map(measured) do
    if Enum.all?(@metrics, fn key -> numeric?(measured[key]) end) and
         measured["source_mode"] == "source" and measured["recovery_data_intact"] == true and
         valid_corpora?(measured["corpus_ids"]) do
      errors
    else
      ["missing_or_untrusted_measurements" | errors]
    end
  end

  defp missing_observations(errors, _), do: ["missing_or_untrusted_measurements" | errors]

  defp missing_approval(errors, %{"approved" => true, "owner" => owner} = approval)
       when is_binary(owner) and byte_size(owner) > 0 do
    if Enum.all?(@thresholds, fn key -> numeric?(approval[key]) end),
      do: errors,
      else: ["missing_owner_approved_thresholds" | errors]
  end

  defp missing_approval(errors, _), do: ["missing_owner_approved_thresholds" | errors]

  defp high_severity(errors, findings) when is_list(findings) do
    cond do
      Enum.any?(findings, fn
        %{"severity" => severity, "status" => status}
        when severity in ["high", "critical"] and status != "closed" ->
          true

        _ ->
          false
      end) ->
        ["open_high_severity_blocker" | errors]

      not Enum.all?(findings, fn
        %{"severity" => severity, "status" => status}
        when severity in ["low", "medium", "high", "critical"] and
               status in ["open", "active", "closed", "resolved"] ->
          true

        _ ->
          false
      end) ->
        ["invalid_risk_register" | errors]

      true ->
        errors
    end
  end

  defp high_severity(errors, _), do: ["invalid_risk_register" | errors]

  defp breached_limits(errors, measured, approval)
       when is_map(measured) and is_map(approval) do
    Enum.zip(@metrics, @thresholds)
    |> Enum.reduce(errors, fn {measured_key, cap}, acc ->
      if numeric?(measured[measured_key]) and numeric?(approval[cap]) and
           measured[measured_key] > approval[cap],
         do: ["budget_exceeded:" <> measured_key | acc],
         else: acc
    end)
  end

  defp breached_limits(errors, _, _), do: errors

  defp numeric?(value), do: is_integer(value) and value >= 0

  defp valid_corpora?(ids) when is_list(ids),
    do: length(Enum.uniq(ids)) >= 3 and Enum.all?(ids, &(is_binary(&1) and byte_size(&1) > 0))

  defp valid_corpora?(_), do: false
end
