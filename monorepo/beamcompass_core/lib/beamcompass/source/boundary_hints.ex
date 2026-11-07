defmodule BeamCompass.Source.BoundaryHints do
  @moduledoc """
  Source-only v2 boundary observations. These facts never enter the v1 scanner.

  Branching syntax is a decision candidate; `try`, `raise` and process monitor
  syntax are failure candidates. Static supervisor child lists are possible
  restart relationships, NOT evidence that a child was started or restarted.
  """

  alias BeamCompass.Id
  alias BeamCompass.Model.Fact

  @spec scan(binary(), String.t()) :: list(Fact.t())
  def scan(bytes, path) when is_binary(bytes) do
    case Code.string_to_quoted(bytes, columns: true, file: path) do
      {:ok, ast} ->
        ast
        |> modules()
        |> Enum.flat_map(fn {name, forms} -> module_facts(name, forms, path, bytes) end)
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(& &1.id)

      {:error, _} ->
        []
    end
  end

  defp modules(ast) do
    {_, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [name, [do: body]]} = node, acc ->
          {node, [{Macro.to_string(name), blocks(body)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(modules)
  end

  defp blocks({:__block__, _, parts}), do: parts
  defp blocks(node), do: [node]

  defp module_facts(name, forms, path, bytes) do
    forms
    |> Enum.flat_map(fn
      {visibility, meta, [head, body]} when visibility in [:def, :defp] and is_list(body) ->
        case function_head(head) do
          {function, arity} ->
            subject = "#{name}.#{function}/#{arity}"
            clause = Macro.to_string(head)
            expression = Keyword.get(body, :do)
            scan_expression(expression, subject, clause, meta, path, bytes)

          nil ->
            []
        end

      _ ->
        []
    end)
  end

  defp function_head({:when, _, [head | _]}), do: function_head(head)

  defp function_head({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp function_head({name, _, nil}) when is_atom(name), do: {name, 0}
  defp function_head(_), do: nil

  defp scan_expression(nil, _, _, _, _, _), do: []

  defp scan_expression(expr, subject, clause, fallback_meta, path, bytes) do
    {_, events} =
      Macro.prewalk(expr, [], fn node, events ->
        case event(node) do
          nil ->
            {node, events}

          {kind, object, meta, details} ->
            {node, [{kind, object, meta, details} | events]}
        end
      end)

    direct = Enum.reverse(events) ++ return_candidates(expr)
    children = static_children(expr, subject, clause, fallback_meta)

    (direct ++ children)
    |> Enum.with_index(1)
    |> Enum.map(fn {{kind, object, meta, details}, occurrence} ->
      line = max(1, Keyword.get(meta, :line, Keyword.get(fallback_meta, :line, 1)))
      column = max(1, Keyword.get(meta, :column, Keyword.get(fallback_meta, :column, 1)))

      snippet =
        bytes
        |> String.split("\n")
        |> Enum.at(line - 1, "")
        |> String.trim()
        |> String.slice(0, 240)

      %Fact{
        id: Id.for_parts([path, kind, subject, object, clause, occurrence]),
        kind: kind,
        subject: subject,
        object: object,
        status: :proposed,
        anchor: %{"path" => path, "line" => line, "column" => column, "snippet" => snippet},
        details: Map.put(details, "clause", clause)
      }
    end)
  end

  # A literal {tuple, result, effects} is only a source candidate. No
  # function is invoked and no state/effect semantics are inferred as observed.
  defp return_candidates(expr) do
    {_, candidates} =
      Macro.prewalk(expr, [], fn
        {:{}, meta, [{:{}, _, fields} = state, _result, effects]} = node, acc
        when is_list(effects) ->
          transition =
            {:transition_candidate, Macro.to_string(state), meta,
             %{"basis" => "literal_tuple_return_candidate", "fields" => length(fields)}}

          {node, [transition | literal_effects(effects, meta)] ++ acc}

        {:{}, meta, [{_left, _right} = state, _result, effects]} = node, acc
        when is_list(effects) ->
          transition =
            {:transition_candidate, Macro.to_string(state), meta,
             %{"basis" => "literal_tuple_return_candidate", "fields" => 2}}

          {node, [transition | literal_effects(effects, meta)] ++ acc}

        {:{}, meta, [_state, _result, effects]} = node, acc when is_list(effects) ->
          {node, literal_effects(effects, meta) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(candidates)
  end

  defp literal_effects(effects, meta) do
    Enum.flat_map(effects, fn
      {tag, _} when is_atom(tag) -> literal_intent(tag, meta)
      {:{}, location, [tag | _]} when is_atom(tag) -> literal_intent(tag, location)
      _ -> []
    end)
  end

  defp literal_intent(tag, meta) when tag not in [:dispatch, :emit, :effect, :command] do
    [
      {:intent_candidate, Atom.to_string(tag), meta,
       %{"basis" => "literal_return_effect_list", "anchor_quality" => "return_tuple_start"}}
    ]
  end

  defp literal_intent(_, _), do: []

  defp event({kind, meta, _}) when kind in [:if, :unless, :case, :cond, :with, :receive] do
    {:decision, Atom.to_string(kind), meta, %{"basis" => "branch_or_receive_syntax"}}
  end

  defp event({:try, meta, _}), do: {:failure_boundary, "try", meta, %{"basis" => "try_syntax"}}

  defp event({kind, meta, _}) when kind in [:raise, :reraise, :throw, :exit] do
    {:failure_boundary, Atom.to_string(kind), meta, %{"basis" => "local_failure_syntax"}}
  end

  defp event({{:., _, [owner, method]}, meta, _args})
       when method in [:monitor, :demonitor, :exit] do
    if Macro.to_string(owner) == "Process" do
      {:failure_boundary, "Process.#{method}", meta, %{"basis" => "process_lifecycle_syntax"}}
    end
  end

  defp event(_), do: nil

  defp static_children(expr, subject, clause, fallback_meta) do
    if String.ends_with?(subject, ".init/1") do
      {_, children} =
        Macro.prewalk(expr, [], fn
          {:=, _, [{:children, _, _}, items]} = node, acc when is_list(items) ->
            {node, items ++ acc}

          node, acc ->
            {node, acc}
        end)

      has_init =
        Macro.prewalk(expr, false, fn
          {{:., _, [owner, :init]}, _, [{:children, _, _}, _opts]} = node, _acc ->
            {node, Macro.to_string(owner) == "Supervisor"}

          node, found ->
            {node, found}
        end)
        |> elem(1)

      child_facts(has_init, children, subject, clause, fallback_meta)
    else
      []
    end
  end

  defp child_facts(false, _children, _subject, _clause, _meta), do: []

  defp child_facts(true, children, subject, clause, meta) do
    children
    |> Enum.filter(&match?({:__aliases__, _, _}, &1))
    |> Enum.map(fn child ->
      {:supervisor_child, Macro.to_string(child), meta,
       %{
         "basis" => "literal_supervisor_children",
         "declaring_module" => module_of(subject),
         "clause" => clause
       }}
    end)
  end

  defp module_of(subject), do: Regex.replace(~r/\.[^.]+\/\d+$/, subject, "")
end
