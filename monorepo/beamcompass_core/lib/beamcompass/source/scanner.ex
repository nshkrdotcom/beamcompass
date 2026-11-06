defmodule BeamCompass.Source.Scanner do
  @moduledoc """
  Non-executing Elixir AST scanner. It records syntactic facts and conservative
  candidates, never claims to recover the complete runtime call graph.
  """

  alias BeamCompass.Id
  alias BeamCompass.Model.Fact

  @handler_names [:handle_call, :handle_cast, :handle_info]
  @intent_tags [:dispatch, :emit, :effect, :command]

  @spec scan(binary(), String.t()) :: {:ok, list(Fact.t())} | {:error, String.t()}
  def scan(source, relative_path) do
    case Code.string_to_quoted(source, columns: true, file: relative_path) do
      {:ok, ast} ->
        modules = find_modules(ast)

        facts =
          modules
          |> Enum.flat_map(fn {name, module_ast, meta} ->
            scan_module(name, module_ast, meta, source, relative_path)
          end)
          |> Enum.uniq_by(& &1.id)
          |> Enum.sort_by(& &1.id)

        {:ok, facts}

      {:error, {location, message, token}} ->
        {:error, "#{inspect(location)}: #{message} #{inspect(token)}"}
    end
  end

  defp find_modules(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [name, [do: body]]} = node, acc ->
          {node, [{Macro.to_string(name), body, meta} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp scan_module(module_name, body, meta, source, path) do
    module_fact =
      make_fact(:module, module_name, "definition", :source, meta, {path, source}, %{}, 0)

    [module_fact | Enum.flat_map(forms(body), &scan_form(&1, module_name, source, path))]
  end

  defp forms({:__block__, _, expressions}), do: expressions
  defp forms(expression), do: [expression]

  defp scan_form({:use, meta, [behaviour | _options]}, module_name, source, path) do
    name = Macro.to_string(behaviour)

    if name in ["GenServer", "Supervisor", "Agent", "GenStage", ":gen_statem"] do
      [make_fact(:role, module_name, name, :source, meta, {path, source}, %{}, 0)]
    else
      []
    end
  end

  defp scan_form({visibility, meta, [head, body]}, module_name, source, path)
       when visibility in [:def, :defp] and is_list(body) do
    case function_head(head) do
      {:ok, function, args} ->
        subject = "#{module_name}.#{function}/#{length(args)}"
        head_text = Macro.to_string(head)
        details = %{"clause" => head_text, "visibility" => Atom.to_string(visibility)}

        function_fact =
          make_fact(:function, subject, head_text, :source, meta, {path, source}, details, 0)

        handler_facts =
          if function in @handler_names and length(args) in [2, 3] do
            [
              make_fact(
                :handler,
                subject,
                Macro.to_string(hd(args)),
                :source,
                meta,
                {path, source},
                %{"clause" => head_text},
                0
              )
            ]
          else
            []
          end

        expression = Keyword.get(body, :do)
        events = collect_events(expression, meta)

        derived_facts =
          events
          |> Enum.with_index(1)
          |> Enum.map(fn {event, index} ->
            make_fact(
              event.kind,
              subject,
              event.object,
              event.status,
              event.meta,
              {path, source},
              Map.put(event.details, "clause", head_text),
              index
            )
          end)

        [function_fact] ++ handler_facts ++ derived_facts

      :error ->
        []
    end
  end

  defp scan_form(_, _, _, _), do: []

  defp function_head({:when, _, [head | _]}), do: function_head(head)
  defp function_head({name, _, args}) when is_atom(name) and is_list(args), do: {:ok, name, args}
  defp function_head({name, _, nil}) when is_atom(name), do: {:ok, name, []}
  defp function_head(_), do: :error

  defp collect_events(nil, _fallback_meta), do: []

  defp collect_events(expression, fallback_meta) do
    {_, events} =
      Macro.prewalk(expression, [], fn node, acc ->
        {node, Enum.reverse(events_for(node, fallback_meta), acc)}
      end)

    Enum.reverse(events)
  end

  defp events_for({{:., meta, [receiver, function]}, call_meta, args}, _fallback_meta)
       when is_atom(function) and is_list(args) do
    module = Macro.to_string(receiver)
    target = "#{module}.#{function}/#{length(args)}"
    location = if is_list(call_meta), do: call_meta, else: meta

    call = %{kind: :call, object: target, status: :source, meta: location, details: %{}}

    effects =
      case effect_category(module, function) do
        nil ->
          []

        category ->
          [
            %{
              kind: :effect_site,
              object: target,
              status: :source,
              meta: location,
              details: %{"category" => category, "certainty" => "syntactic_site_only"}
            }
          ]
      end

    unknowns =
      if function == :apply or target in ["Kernel.apply/3", ":erlang.apply/3"] do
        [
          %{
            kind: :unresolved,
            object: target,
            status: :unresolved,
            meta: location,
            details: %{"reason" => "dynamic_dispatch"}
          }
        ]
      else
        []
      end

    [call] ++ effects ++ unknowns
  end

  defp events_for({:send, meta, [receiver, message]}, _fallback_meta) do
    [
      %{
        kind: :message_send,
        object: Macro.to_string(message),
        status: :source,
        meta: meta,
        details: %{"receiver_expression" => Macro.to_string(receiver)}
      },
      %{
        kind: :unresolved,
        object: "send/2 destination",
        status: :unresolved,
        meta: meta,
        details: %{"reason" => "recipient_not_statically_resolved"}
      }
    ]
  end

  defp events_for({:apply, meta, args}, _fallback_meta) when is_list(args) do
    [
      %{
        kind: :unresolved,
        object: "apply/#{length(args)}",
        status: :unresolved,
        meta: meta,
        details: %{"reason" => "dynamic_dispatch"}
      }
    ]
  end

  defp events_for({:%, meta, [name, _fields]}, _fallback_meta) do
    name_text = Macro.to_string(name)

    if String.contains?(name_text, "Intent") or String.ends_with?(name_text, "Effect") do
      [
        %{
          kind: :intent_candidate,
          object: name_text,
          status: :proposed,
          meta: meta,
          details: %{"basis" => "struct_constructor_name"}
        }
      ]
    else
      []
    end
  end

  defp events_for({:{}, meta, [tag | _rest]}, _fallback_meta) when tag in @intent_tags do
    [
      %{
        kind: :intent_candidate,
        object: Atom.to_string(tag),
        status: :proposed,
        meta: meta,
        details: %{"basis" => "tuple_tag"}
      }
    ]
  end

  # Elixir represents two-element literal tuples as plain two-element AST tuples,
  # with no token location. Anchor such candidates conservatively to the clause.
  defp events_for({tag, _payload}, fallback_meta) when tag in @intent_tags do
    [
      %{
        kind: :intent_candidate,
        object: Atom.to_string(tag),
        status: :proposed,
        meta: fallback_meta,
        details: %{"basis" => "tuple_tag", "anchor_quality" => "clause_start"}
      }
    ]
  end

  defp events_for(_, _fallback_meta), do: []

  defp effect_category(module, function) do
    cond do
      module in ["File", "IO", "Port", "System"] ->
        "environment_io"

      module in [":ets", ":dets", ":mnesia"] ->
        "shared_or_persistent_state"

      module in [":gen_tcp", ":ssl", "Req", "Finch", "Mint"] ->
        "network"

      true ->
        process_or_persistence_effect(module, function)
    end
  end

  defp process_or_persistence_effect(module, function) do
    cond do
      module in ["GenServer", "Phoenix.PubSub", "Process"] and
          function in [:call, :cast, :send, :broadcast, :exit] ->
        "process_communication"

      module in ["Task", "Supervisor", "DynamicSupervisor"] and
          function in [:start, :start_link, :start_child, :async] ->
        "process_lifecycle"

      String.ends_with?(module, ".Repo") and
          function in [:insert, :update, :delete, :transaction, :insert!, :update!, :delete!] ->
        "persistence"

      true ->
        nil
    end
  end

  defp make_fact(kind, subject, object, status, meta, {path, source}, details, occurrence) do
    clause = Map.get(details, "clause", "")
    id = Id.for_parts([path, kind, subject, object, clause, occurrence])
    line = max(1, Keyword.get(meta, :line, 1))
    column = max(1, Keyword.get(meta, :column, 1))

    snippet =
      source
      |> String.split("\n")
      |> Enum.at(line - 1, "")
      |> String.trim()
      |> String.slice(0, 240)

    %Fact{
      id: id,
      kind: kind,
      subject: subject,
      object: object,
      status: status,
      anchor: %{"path" => path, "line" => line, "column" => column, "snippet" => snippet},
      details: details
    }
  end
end
