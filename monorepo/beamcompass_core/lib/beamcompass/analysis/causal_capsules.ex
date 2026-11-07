defmodule BeamCompass.Analysis.CausalCapsules do
  @moduledoc """
  Bounded source-possible slices rooted at v2 handler trigger declarations.

  Each edge retains its original v2 type, resolution and provenance. `calls`
  and `causally_related` edges are not observations or guaranteed invocation;
  message and tag joins remain merely possible. Truncation is explicit.
  """

  alias BeamCompass.Id

  @hops 8
  @entities 96
  @relations 192
  @traverse ~w(causally_related calls describes_effect performs_effect updates_state may_deliver_to supervises may_restart)

  @spec build(map()) :: list(map())
  def build(snapshot) do
    entities = Map.new(snapshot["entities"], &{&1["id"], &1})
    outgoing = Enum.group_by(snapshot["relations"], & &1["source_id"])
    incoming = Enum.group_by(snapshot["relations"], & &1["target_id"])

    snapshot["entities"]
    |> Enum.filter(&(&1["kind"] == "trigger"))
    |> Enum.map(fn trigger ->
      context = %{entities: entities, outgoing: outgoing, incoming: incoming}
      state = %{nodes: %{}, links: %{}, unknown: %{}, cuts: %{}, seen: %{}}
      state = visit([{trigger["id"], 0}], state, context)
      node_ids = ids(state.nodes)
      link_ids = ids(state.links)

      %{
        "id" => "capsule:" <> Id.for_parts(["capsule", snapshot["snapshot_id"], trigger["id"]]),
        "trigger_id" => trigger["id"],
        "entity_ids" => node_ids,
        "relation_ids" => link_ids,
        "unresolved_relation_ids" => ids(state.unknown),
        "cut_relation_ids" => ids(state.cuts),
        "truncated" => map_size(state.cuts) > 0,
        "coverage" => "bounded_syntactic_possible",
        "ordering" => "not_observed_or_runtime_proven"
      }
    end)
    |> Enum.sort_by(& &1["id"])
  end

  defp ids(lookup), do: lookup |> Map.keys() |> Enum.sort()

  defp visit([], state, _context), do: state

  defp visit([{id, depth} | rest], state, context) do
    cond do
      Map.has_key?(state.seen, id) ->
        visit(rest, state, context)

      map_size(state.nodes) >= @entities and not Map.has_key?(state.nodes, id) ->
        # A queued target is admitted into nodes by follow/4. This guard only
        # blocks unexpected unreserved inputs, never already accepted targets.
        visit(rest, state, context)

      true ->
        state = %{
          state
          | seen: Map.put(state.seen, id, true),
            nodes: Map.put(state.nodes, id, true)
        }

        state = attach_handler_owner(id, state, context)

        {state, queued} =
          context.outgoing
          |> Map.get(id, [])
          |> Enum.sort_by(& &1["id"])
          |> Enum.reduce({state, []}, fn relation, {acc, queue} ->
            follow(relation, depth, acc, queue)
          end)

        visit(rest ++ Enum.reverse(queued), state, context)
    end
  end

  defp attach_handler_owner(id, state, context) do
    if context.entities[id]["kind"] == "trigger" do
      context.incoming
      |> Map.get(id, [])
      |> Enum.filter(&(&1["kind"] == "handles"))
      |> Enum.reduce(state, &attach_owner(&1, &2, context))
    else
      state
    end
  end

  defp attach_owner(relation, acc, context) do
    actor_id = relation["source_id"]

    if Map.has_key?(acc.nodes, actor_id) or map_size(acc.nodes) < @entities do
      acc
      |> put_link(relation)
      |> put_node(actor_id)
      |> attach_state_holder(actor_id, context)
      |> attach_supervision(actor_id, context)
    else
      put_cut(acc, relation["id"])
    end
  end

  defp attach_state_holder(state, actor_id, context) do
    context.outgoing
    |> Map.get(actor_id, [])
    |> Enum.filter(&(&1["kind"] == "owns_state"))
    |> Enum.reduce(state, fn relation, acc ->
      if Map.has_key?(acc.nodes, relation["target_id"]) or map_size(acc.nodes) < @entities do
        acc |> put_link(relation) |> put_node(relation["target_id"])
      else
        put_cut(acc, relation["id"])
      end
    end)
  end

  defp attach_supervision(state, actor_id, context) do
    context.incoming
    |> Map.get(actor_id, [])
    |> Enum.filter(&(&1["kind"] in ~w(supervises may_restart)))
    |> Enum.reduce(state, fn relation, acc ->
      source = relation["source_id"]

      if Map.has_key?(acc.nodes, source) or map_size(acc.nodes) < @entities do
        acc |> put_link(relation) |> put_node(source)
      else
        put_cut(acc, relation["id"])
      end
    end)
  end

  defp put_node(state, nil), do: state
  defp put_node(state, id), do: %{state | nodes: Map.put(state.nodes, id, true)}

  defp put_link(state, relation) do
    if map_size(state.links) >= @relations do
      put_cut(state, relation["id"])
    else
      state = %{state | links: Map.put(state.links, relation["id"], true)}

      if relation["resolution"] == "unresolved" do
        %{state | unknown: Map.put(state.unknown, relation["id"], true)}
      else
        state
      end
    end
  end

  defp put_cut(state, id), do: %{state | cuts: Map.put(state.cuts, id, true)}

  defp follow(relation, depth, state, queued) do
    target = relation["target_id"]

    cond do
      relation["resolution"] == "unresolved" ->
        {put_link(state, relation), queued}

      relation["kind"] not in @traverse or is_nil(target) ->
        {state, queued}

      depth >= @hops or
        (not Map.has_key?(state.nodes, target) and map_size(state.nodes) >= @entities) or
          map_size(state.links) >= @relations ->
        {put_cut(state, relation["id"]), queued}

      true ->
        # Reserve the target immediately, rather than counting only the local
        # queue. Previously, another pending traversal branch could overfill
        # the entity budget and leave a retained link with no capsule member.
        accepted = state |> put_link(relation) |> put_node(target)
        {accepted, [{target, depth + 1} | queued]}
    end
  end
end
