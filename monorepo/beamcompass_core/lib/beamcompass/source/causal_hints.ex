defmodule BeamCompass.Source.CausalHints do
  @moduledoc """
  Nonexecuting *candidate* message, alias-call and callback-capture hints.

  Parse literal OTP addresses/tags and direct lexical aliases, never process
  identities, deliveries, macro expansions, guard outcomes or runtime order.
  Every hint must be matched to a real scanner fact before export.
  """

  @spec scan(binary()) :: list(map())
  def scan(bytes) when is_binary(bytes) do
    case Code.string_to_quoted(bytes, columns: true) do
      {:ok, ast} -> ast |> modules() |> Enum.flat_map(&module_hints/1)
      {:error, _} -> []
    end
  end

  @doc "A source-possible payload match. No generic variable-only routing."
  @spec payload_matches?(String.t(), String.t()) :: boolean()
  def payload_matches?(payload, pattern) do
    with {:ok, sent} <- Code.string_to_quoted(payload),
         {:ok, received} <- Code.string_to_quoted(pattern) do
      discriminating?(sent) and discriminating?(received) and compatible?(sent, received)
    else
      _ -> false
    end
  end

  @doc "Check a variable's syntactic position across a literal tuple message."
  @spec transferred_variable?(String.t(), String.t(), String.t(), String.t()) :: boolean()
  def transferred_variable?(payload, pattern, source_variable, target_variable) do
    with {:ok, left} <- Code.string_to_quoted(payload),
         {:ok, right} <- Code.string_to_quoted(pattern) do
      transfer_pairs(left, right)
      |> Enum.any?(fn {from, to} -> from == source_variable and to == target_variable end)
    else
      _ -> false
    end
  end

  defp transfer_pairs({:{}, _, left}, {:{}, _, right}) when length(left) == length(right) do
    Enum.zip(left, right) |> Enum.flat_map(fn {a, b} -> transfer_pairs(a, b) end)
  end

  defp transfer_pairs({a, b}, {c, d}), do: transfer_pairs(a, c) ++ transfer_pairs(b, d)

  defp transfer_pairs(left, right) do
    if variable?(left) and variable?(right) do
      [{Atom.to_string(elem(left, 0)), Atom.to_string(elem(right, 0))}]
    else
      []
    end
  end

  defp discriminating?({:{}, _, [head | _]}), do: is_atom(head)
  defp discriminating?({head, _}) when is_atom(head), do: true
  defp discriminating?(value) when is_atom(value), do: true
  defp discriminating?(_), do: false

  defp compatible?(left, right) when is_atom(left) and is_atom(right), do: left == right
  defp compatible?({:{}, _, ls}, {:{}, _, rs}), do: match_parts(ls, rs)
  defp compatible?({la, lb}, {ra, rb}), do: match_parts([la, lb], [ra, rb])
  defp compatible?(ls, rs) when is_list(ls) and is_list(rs), do: match_parts(ls, rs)

  defp compatible?(left, right) do
    if variable?(left) or variable?(right),
      do: true,
      else: Macro.to_string(left) == Macro.to_string(right)
  end

  defp match_parts(left, right) do
    length(left) == length(right) and
      Enum.zip(left, right) |> Enum.all?(fn {a, b} -> compatible?(a, b) end)
  end

  defp variable?({name, _, scope}) when is_atom(name) and (is_atom(scope) or is_nil(scope)),
    do: true

  defp variable?(_), do: false

  defp modules(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [name, [do: body]]} = node, acc ->
          {node, [{Macro.to_string(name), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp module_hints({module_name, body}) do
    {_aliases, hints} =
      Enum.reduce(forms(body), {%{}, []}, fn form, {aliases, hints} ->
        updated = module_aliases([form], aliases)
        {updated, hints ++ form_hints(form, module_name, aliases)}
      end)

    hints
  end

  defp form_hints({visibility, _, [head, options]}, module_name, aliases)
       when visibility in [:def, :defp] and is_list(options) do
    case head_name(head) do
      {name, arity} ->
        calls(
          Keyword.get(options, :do),
          module_name,
          "#{module_name}.#{name}/#{arity}",
          Macro.to_string(head),
          aliases
        )

      nil ->
        []
    end
  end

  defp form_hints(_, _, _), do: []

  defp module_aliases(module_forms, initial) do
    module_forms
    |> Enum.reduce(initial, fn
      {:alias, _, [name]}, aliases ->
        text = Macro.to_string(name)
        Map.put(aliases, text |> String.split(".") |> List.last(), text)

      {:alias, _, [name, opts]}, aliases when is_list(opts) ->
        text = Macro.to_string(name)

        alias_text =
          opts |> Keyword.get(:as, name) |> Macro.to_string() |> String.split(".") |> List.last()

        Map.put(aliases, alias_text, text)

      _, aliases ->
        aliases
    end)
  end

  defp forms({:__block__, _, expressions}), do: expressions
  defp forms(expression), do: [expression]
  defp head_name({:when, _, [head | _]}), do: head_name(head)
  defp head_name({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head_name({name, _, nil}) when is_atom(name), do: {name, 0}
  defp head_name(_), do: nil
  defp calls(nil, _, _, _, _), do: []

  defp calls(expression, module_name, subject, clause, aliases) do
    {_, hints} =
      Macro.prewalk(expression, [], fn node, acc ->
        case hint(node, module_name, subject, clause, aliases) do
          nil -> {node, acc}
          value -> {node, [value | acc]}
        end
      end)

    Enum.reverse(hints)
  end

  defp location(meta),
    do: %{
      line: max(1, Keyword.get(meta, :line, 1)),
      column: max(1, Keyword.get(meta, :column, 1))
    }

  defp basic(module_name, subject, clause, meta) do
    Map.merge(%{module: module_name, subject: subject, clause: clause}, location(meta))
  end

  defp hint({{:., _, [receiver, operation]}, meta, args}, module_name, subject, clause, _aliases)
       when operation in [:call, :cast] and is_list(args) and length(args) in [2, 3] do
    if Macro.to_string(receiver) == "GenServer" do
      [destination, message | _] = args

      Map.merge(basic(module_name, subject, clause, meta), %{
        kind: :genserver,
        call: "GenServer.#{operation}/#{length(args)}",
        receiver: Macro.to_string(destination),
        payload: Macro.to_string(message),
        handler: if(operation == :call, do: "handle_call/3", else: "handle_cast/2")
      })
    end
  end

  defp hint(
         {:=, meta, [pattern, {{:., _, [receiver, function]}, _, args}]},
         module_name,
         subject,
         clause,
         aliases
       )
       when is_atom(function) and is_list(args) do
    owner = Macro.to_string(receiver)

    if Map.has_key?(aliases, owner) do
      # Only the final return-slot of a literal tuple can be treated as a
      # candidate emitted-effect collection. Another bound value (e.g. new
      # state) is not interchangeable with effect data.
      variable =
        case pattern do
          {:{}, _, elements} -> elements |> List.last() |> variable_name()
          other -> variable_name(other)
        end

      if is_nil(variable) do
        assignment_hint(pattern, meta, module_name, subject, clause)
      else
        Map.merge(basic(module_name, subject, clause, meta), %{
          kind: :result_binding,
          target: "#{aliases[owner]}.#{function}/#{length(args)}",
          variables: [variable]
        })
      end
    else
      assignment_hint(pattern, meta, module_name, subject, clause)
    end
  end

  defp hint({:=, meta, [pattern, _value]}, module_name, subject, clause, _aliases) do
    assignment_hint(pattern, meta, module_name, subject, clause)
  end

  defp hint({:send, meta, [destination, payload]}, module_name, subject, clause, _aliases) do
    Map.merge(basic(module_name, subject, clause, meta), %{
      kind: :send,
      receiver: Macro.to_string(destination),
      payload: Macro.to_string(payload),
      handler: "handle_info/2"
    })
  end

  defp hint(
         {{:., _, [receiver, :each]}, meta, [collection, capture]},
         module_name,
         subject,
         clause,
         aliases
       ) do
    if Macro.to_string(receiver) == "Enum" do
      case Regex.run(
             ~r/^&([A-Z][A-Za-z0-9_.]*)\.([a-z_][a-zA-Z0-9_!?]*)\/(\d+)$/,
             Macro.to_string(capture)
           ) do
        [_, owner, function, arity] ->
          Map.merge(basic(module_name, subject, clause, meta), %{
            kind: :capture,
            call: "Enum.each/2",
            receiver: normalize_owner(owner, aliases),
            target: "#{normalize_owner(owner, aliases)}.#{function}/#{arity}",
            collection: Macro.to_string(collection)
          })

        _ ->
          nil
      end
    end
  end

  defp hint({{:., _, [receiver, function]}, meta, args}, module_name, subject, clause, aliases)
       when is_atom(function) and is_list(args) do
    owner = Macro.to_string(receiver)

    if Map.has_key?(aliases, owner) do
      Map.merge(basic(module_name, subject, clause, meta), %{
        kind: :alias_call,
        call: "#{owner}.#{function}/#{length(args)}",
        target: "#{aliases[owner]}.#{function}/#{length(args)}"
      })
    end
  end

  defp hint(_, _, _, _, _), do: nil

  defp assignment_hint(pattern, meta, module_name, subject, clause) do
    {_, names} =
      Macro.prewalk(pattern, [], fn node, names ->
        case variable_name(node) do
          nil -> {node, names}
          name -> {node, [name | names]}
        end
      end)

    Map.merge(basic(module_name, subject, clause, meta), %{
      kind: :assignment,
      variables: Enum.uniq(names)
    })
  end

  defp variable_name({name, _, scope}) when is_atom(name) and (is_atom(scope) or is_nil(scope)),
    do: Atom.to_string(name)

  defp variable_name(_), do: nil

  defp normalize_owner(owner, aliases) do
    [first | tail] = String.split(owner, ".")
    Enum.join([Map.get(aliases, first, first) | tail], ".")
  end
end
