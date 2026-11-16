defmodule LemonCore.Quality.GlobalTransContractTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../../..", __DIR__)

  test "every application source transaction is node-local with finite acquisition retries" do
    paths = Path.wildcard(Path.join(@repo_root, "apps/*/{lib,priv}/**/*.{ex,exs}"))
    assert paths != []

    violations =
      Enum.flat_map(paths, fn path ->
        path
        |> File.read!()
        |> Code.string_to_quoted!(file: path)
        |> violations()
        |> Enum.map(fn {line, reason} ->
          "#{Path.relative_to(path, @repo_root)}:#{line}: #{reason}"
        end)
      end)

    assert violations == [], Enum.join(violations, "\n")
  end

  test "checks syntax rather than comments or strings, including generated macro bodies" do
    assert violations(
             Code.string_to_quoted!(~S"""
             # :global.trans(lock, fun)
             @doc ":global.trans(lock, fun, [node()], :infinity)"
             quote do
               :global.trans({resource, self()}, fn -> :ok end, [node()], 3)
             end
             """)
           ) == []

    assert [_] = violations(Code.string_to_quoted!("quote do: :global.trans(lock, fun)"))
  end

  test "rejects implicit scope, implicit retries, infinite and invalid retries" do
    for source <- [
          ":global.trans(lock, fun)",
          ":global.trans(lock, fun, [node()])",
          ":global.trans(lock, fun, [node()], :infinity)",
          ":global.trans(lock, fun, [node()], -1)",
          ":global.trans(lock, fun, [node()], 1.0)",
          ":global.trans(lock, fun, [node()], retries)",
          ":global.trans(lock, fun, [], 3)",
          ":global.trans(lock, fun, [node(), :remote@host], 3)",
          ":global.trans(lock, fun, nodes, 3)",
          "&:global.trans/2",
          "&:global.trans/4",
          "apply(:global, :trans, [lock, fun])",
          ":erlang.apply(:global, :trans, args)"
        ] do
      assert [_ | _] = violations(Code.string_to_quoted!(source)), source
    end
  end

  test "accepts zero retries and explicitly integer-guarded nonnegative retry parameters" do
    for source <- [
          ":global.trans(lock, fun, [node()], 0)",
          "def run(n, fun) when is_integer(n) and n >= 0 do\n" <>
            "  :global.trans(lock, fun, [node()], n)\nend"
        ] do
      assert violations(Code.string_to_quoted!(source)) == []
    end

    for source <- [
          "def run(n, fun) when n >= 0 do",
          "def run(n, fun) when is_integer(n) do",
          "def run(n, fun) when is_integer(n) or n >= 0 do"
        ] do
      ast = Code.string_to_quoted!(source <> "\n:global.trans(lock, fun, [node()], n)\nend")
      assert [_] = violations(ast)
    end

    ast =
      Code.string_to_quoted!("""
      def run(n, fun) when is_integer(n) and n >= 0 do
        n = :infinity
        :global.trans(lock, fun, [node()], n)
      end
      """)

    assert [_] = violations(ast)
  end

  defp violations(ast, finite_variables \\ MapSet.new())

  defp violations({kind, _, [{:when, _, [_head, guard]}, body]}, _finite_variables)
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    guards = conjunctions(guard)

    integers = for {:is_integer, _, [{name, _, context}]} <- guards, is_atom(context), do: name
    nonnegative = for {:>=, _, [{name, _, context}, 0]} <- guards, is_atom(context), do: name

    finite = MapSet.intersection(MapSet.new(integers), MapSet.new(nonnegative))

    # A later rebinding must not turn a guarded integer into an unbounded retry.
    {_, rebound} =
      Macro.prewalk(body, MapSet.new(), fn
        {:=, _, [pattern, _]} = node, names ->
          {_, names} =
            Macro.prewalk(pattern, names, fn
              {name, _, context} = variable, acc when is_atom(name) and is_atom(context) ->
                {variable, MapSet.put(acc, name)}

              node, acc ->
                {node, acc}
            end)

          {node, names}

        node, names ->
          {node, names}
      end)

    violations(body, MapSet.difference(finite, rebound))
  end

  defp violations({kind, _, [_head, body]}, _finite_variables)
       when kind in [:def, :defp, :defmacro, :defmacrop],
       do: violations(body)

  defp violations({{:., _, [:global, :trans]}, meta, args}, finite_variables) do
    valid? =
      case args do
        [_lock, _fun, [{:node, _, []}], retries] -> finite?(retries, finite_variables)
        _ -> false
      end

    errors =
      if valid?,
        do: [],
        else: [
          {meta[:line], "use :global.trans/4 with [node()] and non-negative integer retries"}
        ]

    errors ++ violations(args, finite_variables)
  end

  defp violations({:apply, meta, [:global, :trans, _args]}, _finite_variables),
    do: [{meta[:line], "use an explicit bounded :global.trans/4 call, not apply/3"}]

  defp violations(
         {{:., _, [:erlang, :apply]}, meta, [:global, :trans, _args]},
         _finite_variables
       ),
       do: [{meta[:line], "use an explicit bounded :global.trans/4 call, not apply/3"}]

  defp violations(ast, finite_variables) when is_tuple(ast),
    do: ast |> Tuple.to_list() |> violations(finite_variables)

  defp violations(ast, finite_variables) when is_list(ast),
    do: Enum.flat_map(ast, &violations(&1, finite_variables))

  defp violations(_ast, _finite_variables), do: []

  defp conjunctions({:and, _, [left, right]}), do: conjunctions(left) ++ conjunctions(right)
  defp conjunctions(guard), do: [guard]

  defp finite?(retries, _variables) when is_integer(retries) and retries >= 0, do: true

  defp finite?({name, _, context}, variables) when is_atom(name) and is_atom(context),
    do: MapSet.member?(variables, name)

  defp finite?(_retries, _variables), do: false
end
