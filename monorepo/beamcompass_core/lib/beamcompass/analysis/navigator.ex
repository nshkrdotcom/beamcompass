defmodule BeamCompass.Analysis.Navigator do
  @moduledoc """
  Source-only, versioned navigator *semantics* shared by the Phoenix interface and
  independent headless consumers. A browser only positions/renders these records.

  All object identities are pinned to a validated v2 snapshot. A missing target
  is never silently rebound through labels, semantic keys or nearby revisions.
  Source links describe syntactic possibilities, not observed causal execution.
  """

  alias BeamCompass.Analysis.SourceProjection
  alias BeamCompass.Behavior.Validator

  @format "beamcompass.navigator.view"
  @lenses ~w(behavior effects state failure)
  @kinds ~w(entity relation evidence)
  @fields ~w(project snapshot lens budget focus_kind focus_id selected_kind selected_id)
  @boundaries %{
    "behavior" => ~w(trigger unknown),
    "effects" => ~w(effect intent unknown),
    "state" => ~w(state unknown),
    "failure" => ~w(failure unknown)
  }

  @doc "Project one exact v2 snapshot; returned JSON is consumable without Phoenix."
  @spec view(map(), map()) :: {:ok, map()} | {:error, term()}
  def view(snapshot, query \\ %{})

  def view(snapshot, query) when is_map(snapshot) and is_map(query) do
    with :ok <- Validator.validate(snapshot),
         {:ok, normalized} <- normalize(snapshot, query) do
      render(snapshot, normalized)
    end
  end

  def view(_, _), do: {:error, :invalid_navigation_input}

  @doc "Strict query parser: duplicate keys are errors; no silent overwrite."
  @spec from_query(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def from_query(snapshot, query) when is_binary(query) and byte_size(query) <= 4096 do
    try do
      pairs = URI.query_decoder(query) |> Enum.to_list()
      keys = Enum.map(pairs, &elem(&1, 0))

      if length(keys) == length(Enum.uniq(keys)),
        do: view(snapshot, Map.new(pairs)),
        else: {:error, :duplicate_navigation_field}
    rescue
      ArgumentError -> {:error, :invalid_navigation_encoding}
    end
  end

  def from_query(_, _), do: {:error, :invalid_navigation_encoding}

  @doc "Canonical root-independent deep-link query; host chooses a route prefix."
  @spec query_string(map()) :: String.t()
  def query_string(params) when is_map(params) do
    params
    |> Enum.filter(fn {_k, v} -> is_binary(v) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> URI.encode_query()
  end

  defp normalize(snapshot, query) do
    fields = Map.keys(query)

    cond do
      Enum.any?(fields, &(not is_binary(&1) or &1 not in @fields)) ->
        {:error, :unsupported_navigation_field}

      Enum.any?(Map.values(query), &(not is_binary(&1))) ->
        {:error, :invalid_navigation_value}

      not pair?(query, "focus_kind", "focus_id") ->
        {:error, :incomplete_focus_identity}

      not pair?(query, "selected_kind", "selected_id") ->
        {:error, :incomplete_selection_identity}

      true ->
        build_query(snapshot, query)
    end
  end

  defp pair?(q, kind, id), do: Map.has_key?(q, kind) == Map.has_key?(q, id)

  defp build_query(snapshot, query) do
    lens = Map.get(query, "lens", "behavior")
    budget_text = Map.get(query, "budget", "16")
    budget = Integer.parse(budget_text)

    cond do
      lens not in @lenses ->
        {:error, :unsupported_navigation_lens}

      budget == :error or not valid_budget?(budget) ->
        {:error, :invalid_navigation_budget}

      invalid_pair?(query, "focus_kind", "focus_id", ~w(entity relation)) ->
        {:error, :invalid_focus_identity}

      invalid_pair?(query, "selected_kind", "selected_id", @kinds) ->
        {:error, :invalid_selection_identity}

      true ->
        normalized = %{
          "project" => Map.get(query, "project", snapshot["project_id"]),
          "snapshot" => Map.get(query, "snapshot", snapshot["snapshot_id"]),
          "lens" => lens,
          "budget" => Integer.to_string(elem(budget, 0))
        }

        {:ok, Map.merge(normalized, Map.take(query, ~w(focus_kind focus_id selected_kind selected_id)))}
    end
  end

  defp valid_budget?({value, ""}), do: value in 1..256
  defp valid_budget?(_), do: false

  defp invalid_pair?(q, kind, id, kinds) do
    Map.has_key?(q, kind) and
      (q[kind] not in kinds or not is_binary(q[id]) or byte_size(q[id]) == 0 or
         byte_size(q[id]) > 1024)
  end

  defp render(snapshot, q) do
    cond do
      q["project"] != snapshot["project_id"] ->
        {:ok, unavailable(snapshot, q, "project_unavailable")}

      q["snapshot"] != snapshot["snapshot_id"] ->
        {:ok, unavailable(snapshot, q, "snapshot_unavailable")}

      true ->
        render_local(snapshot, q)
    end
  end

  defp render_local(snapshot, q) do
    with {:ok, focus} <- exact_reference(snapshot, q, "focus"),
         {:ok, selected} <- exact_reference(snapshot, q, "selected") do
      options = [
        lens: q["lens"],
        budget: String.to_integer(q["budget"]),
        focus: focus,
        preserve: if(selected && selected["object_kind"] != "evidence", do: [selected], else: []),
        boundaries: Map.fetch!(@boundaries, q["lens"])
      ]

      with {:ok, request} <- SourceProjection.request(snapshot, options),
           {:ok, projection} <- SourceProjection.project(snapshot, request) do
        indexes = indexes(snapshot)
        visible = projection["visible"]
        nodes = Enum.map(visible, &stage_node(&1, indexes, q))
        edges = Enum.flat_map(visible, &stage_edge(&1, indexes, visible))

        {:ok,
         %{
           "format" => @format,
           "schema_version" => 1,
           "snapshot_schema_version" => 2,
           "project_id" => snapshot["project_id"],
           "snapshot_id" => snapshot["snapshot_id"],
           "status" => "available",
           "diagnostics" => [],
           "lens" => q["lens"],
           "budget" => String.to_integer(q["budget"]),
           "focus" => focus,
           "selection" => selected,
           "navigation" => navigation(q),
           "stage" => %{"nodes" => nodes, "edges" => edges},
           "questions" => questions(snapshot, q),
           "drawer" => drawer(snapshot, selected, indexes, q),
           "projection" => projection,
           "issues" => snapshot["issues"],
           "limitations" => Enum.uniq(snapshot["limitations"] ++ projection["receipt"]["limitations"])
         }}
      end
    else
      {:error, :focus_not_found} -> {:ok, unavailable(snapshot, q, "focus_target_unavailable")}
      {:error, :selected_not_found} -> {:ok, unavailable(snapshot, q, "selected_target_unavailable")}
      {:error, other} -> {:error, other}
    end
  end

  defp exact_reference(snapshot, q, prefix) do
    kind = Map.get(q, prefix <> "_kind")
    id = Map.get(q, prefix <> "_id")

    if is_nil(kind) do
      {:ok, nil}
    else
      case Validator.reference(snapshot, kind, id) do
        {:error, :not_found} -> {:error, if(prefix == "focus", do: :focus_not_found, else: :selected_not_found)}
        value -> value
      end
    end
  end

  defp unavailable(snapshot, q, code) do
    %{
      "format" => @format,
      "schema_version" => 1,
      "snapshot_schema_version" => 2,
      "project_id" => snapshot["project_id"],
      "snapshot_id" => snapshot["snapshot_id"],
      "status" => "unavailable",
      "diagnostics" => [
        %{
          "code" => code,
          "message" => "Pinned navigation target is unavailable in this exact source snapshot; no fallback was used.",
          "requested" => q
        }
      ],
      "lens" => q["lens"],
      "budget" => String.to_integer(q["budget"]),
      "focus" => nil,
      "selection" => nil,
      "navigation" => navigation(q),
      "stage" => %{"nodes" => [], "edges" => []},
      "questions" => [],
      "drawer" => nil,
      "projection" => nil,
      "issues" => snapshot["issues"],
      "limitations" => snapshot["limitations"]
    }
  end

  defp indexes(snapshot) do
    %{
      "entity" => Map.new(snapshot["entities"], &{&1["id"], &1}),
      "relation" => Map.new(snapshot["relations"], &{&1["id"], &1}),
      "evidence" => Map.new(snapshot["evidence"], &{&1["id"], &1})
    }
  end

  defp stage_node(ref, indexes, query) do
    kind = ref["object_kind"]
    record = indexes[kind][ref["object_id"]]
    label = if kind == "entity", do: record["label"], else: record["kind"]

    %{
      "id" => kind <> ":" <> ref["object_id"],
      "reference" => ref,
      "kind" => kind,
      "label" => label,
      "detail" => record["kind"],
      "epistemic_status" => record["epistemic_status"],
      "resolution" => if(kind == "relation", do: record["resolution"], else: nil),
      "href" => href(query, kind, ref["object_id"])
    }
  end

  defp stage_edge(%{"object_kind" => "relation", "object_id" => id}, indexes, visible) do
    record = indexes["relation"][id]
    ids = MapSet.new(Enum.filter(visible, &(&1["object_kind"] == "entity")) |> Enum.map(& &1["object_id"]))

    # A drawn connector is only a representation of an explicit *source relation*;
    # no client-side join or invented target may fill a missing endpoint.
    if MapSet.member?(ids, record["source_id"]) and
         is_binary(record["target_id"]) and MapSet.member?(ids, record["target_id"]) do
      [
        %{
          "id" => id,
          "reference" => ref,
          "source" => "entity:" <> record["source_id"],
          "target" => "entity:" <> record["target_id"],
          "kind" => record["kind"],
          "resolution" => record["resolution"],
          "epistemic_status" => record["epistemic_status"]
        }
      ]
    else
      []
    end
  end

  defp stage_edge(_, _, _), do: []

  defp drawer(_, nil, _, _), do: nil

  defp drawer(snapshot, ref, indexes, q) do
    kind = ref["object_kind"]
    record = indexes[kind][ref["object_id"]]
    evidence_ids = ref["evidence_ids"]

    evidence =
      Enum.map(evidence_ids, fn id ->
        item = indexes["evidence"][id]

        %{
          "id" => id,
          "reference" => reference(snapshot, "evidence", item),
          "mode" => item["mode"],
          "provider_id" => item["provider_id"],
          "anchor" => item["anchor"],
          "basis" => item["basis"],
          "input_evidence_ids" => item["input_evidence_ids"],
          "lineage" => Enum.map(item["input_evidence_ids"], fn parent ->
            %{"id" => parent, "href" => href(q, "evidence", parent)}
          end),
          "href" => href(q, "evidence", id)
        }
      end)

    %{
      "reference" => ref,
      "label" => Map.get(record, "label", Map.get(record, "kind", record["id"])),
      "record" => record,
      "evidence" => evidence,
      "related" => related(snapshot, ref, indexes, q),
      "limitations" => if(kind == "entity", do: record["limitations"], else: [])
    }
  end

  defp reference(snapshot, kind, record) do
    %{
      "provider" => "beamcompass",
      "snapshot_schema_version" => 2,
      "project_id" => snapshot["project_id"],
      "snapshot_id" => snapshot["snapshot_id"],
      "object_kind" => kind,
      "object_id" => record["id"],
      "evidence_ids" => if(kind == "evidence", do: [record["id"]], else: record["evidence_ids"])
    }
  end

  defp related(snapshot, %{"object_kind" => "entity", "object_id" => id}, indexes, q) do
    snapshot["relations"]
    |> Enum.filter(&(&1["source_id"] == id or &1["target_id"] == id))
    |> Enum.map(fn rel ->
      %{
        "role" => if(rel["source_id"] == id, do: "outgoing_source_relation", else: "incoming_source_relation"),
        "kind" => rel["kind"],
        "resolution" => rel["resolution"],
        "reference" => reference(snapshot, "relation", indexes["relation"][rel["id"]]),
        "href" => href(q, "relation", rel["id"])
      }
    end)
  end

  defp related(snapshot, %{"object_kind" => "relation", "object_id" => id}, indexes, q) do
    rel = indexes["relation"][id]

    [
      {"source_endpoint", rel["source_id"]},
      {"target_endpoint", rel["target_id"]}
    ]
    |> Enum.map(fn {role, target} ->
      if is_binary(target) do
        %{
          "role" => role,
          "kind" => indexes["entity"][target]["kind"],
          "resolution" => "present_source_entity",
          "reference" => reference(snapshot, "entity", indexes["entity"][target]),
          "href" => href(q, "entity", target)
        }
      else
        %{"role" => role, "kind" => "unavailable_target", "resolution" => "unresolved", "reference" => nil, "href" => nil}
      end
    end)
  end

  defp related(_, _, _, _), do: []

  # Question-first entrypoints are derived in the trusted core from typed
  # source trigger records. These are navigation prompts, NOT runtime claims or
  # a completeness assertion; the browser only renders the supplied links.
  defp questions(snapshot, q) do
    triggers =
      snapshot["entities"]
      |> Enum.filter(&(&1["kind"] == "trigger"))
      |> Enum.take(4)

    case triggers do
      [] ->
        Enum.map(@lenses, fn lens ->
          %{
            "id" => "source:" <> lens,
            "title" => question_title(lens, nil),
            "source_scope" => "bounded_source_only",
            "href" => "?" <> query_string(Map.put(q, "lens", lens))
          }
        end)

      _ ->
        for trigger <- triggers, lens <- @lenses do
          link =
            q
            |> Map.put("lens", lens)
            |> Map.put("focus_kind", "entity")
            |> Map.put("focus_id", trigger["id"])
            |> Map.put("selected_kind", "entity")
            |> Map.put("selected_id", trigger["id"])

          %{
            "id" => "trigger:" <> trigger["id"] <> ":" <> lens,
            "title" => question_title(lens, trigger["label"]),
            "source_scope" => "bounded_source_only",
            "href" => "?" <> query_string(link)
          }
        end
    end
  end

  defp question_title("behavior", nil), do: "What source behaviors are visible?"
  defp question_title("effects", nil), do: "What effect intentions are present in source?"
  defp question_title("state", nil), do: "What source state relationships are visible?"
  defp question_title("failure", nil), do: "What failure boundaries are visible in source?"

  defp question_title(lens, trigger) do
    case lens do
      "behavior" -> "What source behavior surrounds #{trigger}?"
      "effects" -> "Which effects might be intended around #{trigger}?"
      "state" -> "Which state paths might be relevant to #{trigger}?"
      "failure" -> "Which failure boundaries might surround #{trigger}?"
    end
  end

  defp navigation(q) do
    budget = String.to_integer(q["budget"])

    %{
      "self" => "?" <> query_string(q),
      "lenses" => Map.new(@lenses, &{&1, "?" <> query_string(Map.put(q, "lens", &1))}),
      "zoom_in" => "?" <> query_string(Map.put(q, "budget", Integer.to_string(min(256, budget * 2)))),
      "zoom_out" => "?" <> query_string(Map.put(q, "budget", Integer.to_string(max(1, div(budget, 2)))))
    }
  end

  defp href(q, kind, id) do
    "?" <>
      query_string(
        q
        |> Map.put("selected_kind", kind)
        |> Map.put("selected_id", id)
      )
  end
end
