defmodule BeamCompass.Analysis.SemanticWitness do
  @moduledoc """
  Deterministic bounded source-possible *witness closures* for compression.

  A witness contains the requested record, endpoints of every relation and a
  path of cited source-possible relations back to a syntactic trigger. It does
  not prove runtime causality, guard passage or message delivery. Missing paths
  are reported, never bridged with invented edges. Groups are budgeted atomically.
  """

  @max_hops 8
  @forward ~w(causally_related calls describes_effect performs_effect updates_state may_deliver_to supervises may_restart owns_state handles)
  @reverse_structural ~w(handles owns_state supervises may_restart)

  @spec plan(map(), [map()], [String.t()]) :: map()
  def plan(snapshot, capsules, keys) do
    edge_ids =
      capsules
      |> Enum.flat_map(& &1["relation_ids"])
      |> Enum.uniq()

    valid = Map.new(edge_ids, &{&1, true})
    relations = Enum.filter(snapshot["relations"], &(Map.has_key?(valid, &1["id"])))
    roots = capsules |> Enum.map(& &1["trigger_id"]) |> Enum.uniq() |> Enum.sort()
    adjacency = adjacency(relations)
    records = Map.new(snapshot["entities"], &{"entity:" <> &1["id"], {"entity", &1}})
    records = Map.merge(records, Map.new(snapshot["relations"], &{"relation:" <> &1["id"], {"relation", &1}}))

    Map.new(keys, fn key ->
      {kind, record} = Map.fetch!(records, key)
      goal = if(kind == "entity", do: record["id"], else: record["source_id"])
      path = shortest(roots, goal, adjacency)

      closure =
        if is_nil(path) do
          endpoint_keys(kind, record)
        else
          path_keys(path, records) ++ endpoint_keys(kind, record)
        end

      {key,
       %{
         members: closure |> Enum.uniq() |> Enum.sort(),
         path: if(is_nil(path), do: [], else: Enum.map(path, &("relation:" <> &1))),
         connected: not is_nil(path)
       }}
    end)
  end

  defp endpoint_keys("entity", record), do: ["entity:" <> record["id"]]

  defp endpoint_keys("relation", record) do
    ["relation:" <> record["id"], "entity:" <> record["source_id"]] ++
      if(is_nil(record["target_id"]), do: [], else: ["entity:" <> record["target_id"]])
  end

  defp path_keys(path, records) do
    Enum.flat_map(path, fn id ->
      {"relation", relation} = Map.fetch!(records, "relation:" <> id)
      endpoint_keys("relation", relation)
    end)
  end

  defp adjacency(relations) do
    relations
    |> Enum.reduce(%{}, fn relation, acc ->
      kind = relation["kind"]
      source = relation["source_id"]
      target = relation["target_id"]

      if is_nil(target) or relation["resolution"] == "unresolved" do
        acc
      else
        acc = if kind in @forward, do: add_edge(acc, source, target, relation["id"]), else: acc
        if kind in @reverse_structural, do: add_edge(acc, target, source, relation["id"]), else: acc
      end
    end)
    |> Map.new(fn {node, edges} -> {node, Enum.sort_by(edges, &{elem(&1, 1), elem(&1, 0)})} end)
  end

  defp add_edge(graph, from, to, relation_id) do
    Map.update(graph, from, [{to, relation_id}], &[{to, relation_id} | &1])
  end

  defp shortest([], _goal, _graph), do: nil

  defp shortest(roots, goal, graph) do
    queue = Enum.map(roots, &{&1, []})
    seen = Map.new(roots, &{&1, true})
    walk(queue, seen, goal, graph)
  end

  defp walk([], _seen, _goal, _graph), do: nil
  defp walk([{goal, path} | _], _seen, goal, _graph), do: path

  defp walk([{node, path} | rest], seen, goal, graph) do
    {seen, queue} =
      if length(path) >= @max_hops do
        {seen, []}
      else
        Map.get(graph, node, [])
        |> Enum.reduce({seen, []}, fn {next, relation_id}, {visited, pending} ->
          if Map.has_key?(visited, next) do
            {visited, pending}
          else
            {Map.put(visited, next, true), [{next, path ++ [relation_id]} | pending]}
          end
        end)
      end

    walk(rest ++ Enum.reverse(queue), seen, goal, graph)
  end
end
