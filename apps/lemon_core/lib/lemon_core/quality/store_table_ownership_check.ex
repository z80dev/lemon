defmodule LemonCore.Quality.StoreTableOwnershipCheck do
  @moduledoc """
  AST analysis for modules that opt into `LemonCore.Store.Table` ownership.

  The incremental rule leaves legacy non-owner wrappers to existing migration
  checks. Once a module declares tables, however, every recognized generic
  Store call must resolve to one of those exact names. Aliases, module
  attributes, and both default-server and explicit-server arities count.
  """

  # Generic Store operations and the zero-based table argument at each public
  # arity. Keep both the current API and the ownership-migration primitives in
  # this one explicit contract: adding a generic operation without teaching the
  # check its default-server and explicit-server arities would reopen the bypass
  # this rule exists to close.
  @store_table_arguments %{
    get: %{2 => 0, 3 => 1},
    fetch: %{2 => 0, 3 => 1},
    put: %{3 => 0, 4 => 1},
    put_async: %{3 => 0, 4 => 1},
    put_new: %{3 => 0, 4 => 1},
    delete: %{2 => 0, 3 => 1},
    list: %{1 => 0, 2 => 1},
    list_recent: %{2 => 0, 3 => 1},
    take: %{2 => 0, 3 => 1},
    update: %{4 => 0, 5 => 1},
    update_async: %{4 => 0, 5 => 1},
    compare_and_swap: %{4 => 0, 5 => 1},
    register_cached_table: %{1 => 0, 2 => 1},
    unregister_cached_table: %{1 => 0, 2 => 1}
  }

  @type issue :: %{code: atom(), message: String.t(), path: String.t()}

  @doc "Returns ownership issues from the supplied library source files."
  @spec issues(String.t(), [String.t()]) :: [issue()]
  def issues(root, files) when is_binary(root) and is_list(files) do
    Enum.flat_map(files, &file_issues(root, &1))
  end

  defp file_issues(root, file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true, emit_warnings: false) do
      relative = Path.relative_to(file, root)

      ast
      |> module_bodies()
      |> Enum.flat_map(&module_issues(&1, relative))
    else
      # A source file that cannot be parsed cannot compile either; the compiler
      # remains the useful source of that diagnostic.
      _ -> []
    end
  end

  defp module_bodies({:defmodule, _meta, [_module, [do: body]]}) do
    [strip_nested_modules(body) | module_bodies(body)]
  end

  defp module_bodies(list) when is_list(list), do: Enum.flat_map(list, &module_bodies/1)

  defp module_bodies(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.flat_map(&module_bodies/1)
  end

  defp module_bodies(_other), do: []

  defp strip_nested_modules({:defmodule, _meta, _args}), do: nil
  defp strip_nested_modules(list) when is_list(list), do: Enum.map(list, &strip_nested_modules/1)

  defp strip_nested_modules(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&strip_nested_modules/1)
    |> List.to_tuple()
  end

  defp strip_nested_modules(other), do: other

  defp module_issues(body, relative) do
    attributes = module_attributes(body)
    aliases = store_aliases(body)

    case declared_store_tables(body, attributes, aliases.table) do
      :not_an_owner ->
        []

      {:ok, declared} ->
        body
        |> generic_store_calls(attributes, aliases.store)
        |> Enum.reject(fn
          %{table: {:resolved, name}} -> name in declared
          _call -> false
        end)
        |> Enum.map(&bypass_issue(&1, declared, relative))

      :unresolved ->
        [
          %{
            code: :store_table_declaration_unresolved,
            message:
              "Store.Table declarations must use a literal keyword list or a module attribute " <>
                "containing one so ownership can be verified from source",
            path: relative
          }
        ]
    end
  end

  defp module_attributes(body) do
    {_ast, attributes} =
      Macro.prewalk(body, %{}, fn
        {:@, _meta, [{name, _name_meta, [value]}]} = node, acc when is_atom(name) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  defp store_aliases(body) do
    {_ast, aliases} =
      Macro.prewalk(body, %{store: MapSet.new(), table: MapSet.new()}, fn
        {:alias, _meta, args} = node, acc ->
          {node, collect_store_alias(args, acc)}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp collect_store_alias([{:__aliases__, _meta, [:LemonCore, :Store]} | opts], acc) do
    put_store_alias(acc, :store, alias_name(opts, :Store))
  end

  defp collect_store_alias([{:__aliases__, _meta, [:LemonCore, :Store, :Table]} | opts], acc) do
    put_store_alias(acc, :table, alias_name(opts, :Table))
  end

  defp collect_store_alias(
         [
           {{:., _dot_meta, [{:__aliases__, _base_meta, [:LemonCore]}, :{}]}, _call_meta,
            children}
         ],
         acc
       ) do
    Enum.reduce(children, acc, fn
      {:__aliases__, _meta, [:Store]}, found -> put_store_alias(found, :store, :Store)
      _, found -> found
    end)
  end

  defp collect_store_alias(
         [
           {{:., _dot_meta, [{:__aliases__, _base_meta, [:LemonCore, :Store]}, :{}]}, _call_meta,
            children}
         ],
         acc
       ) do
    Enum.reduce(children, acc, fn
      {:__aliases__, _meta, [:Table]}, found -> put_store_alias(found, :table, :Table)
      _, found -> found
    end)
  end

  defp collect_store_alias(_args, acc), do: acc

  defp alias_name([opts], default) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _meta, [name]} when is_atom(name) -> name
      _ -> default
    end
  end

  defp alias_name(_opts, default), do: default

  defp put_store_alias(aliases, kind, name) do
    Map.update!(aliases, kind, &MapSet.put(&1, name))
  end

  defp declared_store_tables(body, attributes, table_aliases) do
    {_ast, declarations} =
      Macro.prewalk(body, [], fn
        {:use, _meta, [target, opts]} = node, acc when is_list(opts) ->
          if store_table_module?(target, table_aliases) do
            {node, [Keyword.get(opts, :tables) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    case declarations do
      [] ->
        :not_an_owner

      [declaration] ->
        case resolve_attribute(declaration, attributes) do
          tables when is_list(tables) ->
            if Keyword.keyword?(tables) and Enum.all?(Keyword.keys(tables), &is_atom/1) do
              {:ok, Keyword.keys(tables)}
            else
              :unresolved
            end

          _ ->
            :unresolved
        end

      _multiple ->
        :unresolved
    end
  end

  defp store_table_module?({:__aliases__, _meta, [:LemonCore, :Store, :Table]}, _aliases),
    do: true

  defp store_table_module?({:__aliases__, _meta, [name]}, aliases),
    do: MapSet.member?(aliases, name)

  defp store_table_module?(_target, _aliases), do: false

  defp generic_store_calls(body, attributes, store_aliases) do
    {_ast, calls} =
      Macro.prewalk(body, [], fn
        {{:., dot_meta, [target, function]}, call_meta, args} = node, acc
        when is_atom(function) and is_list(args) ->
          with true <- store_module?(target, store_aliases),
               table_index when is_integer(table_index) <-
                 get_in(@store_table_arguments, [function, length(args)]),
               table_expression when not is_nil(table_expression) <- Enum.at(args, table_index) do
            table = resolve_table(table_expression, attributes)
            line = Keyword.get(call_meta, :line) || Keyword.get(dot_meta, :line)
            {node, [%{function: function, arity: length(args), table: table, line: line} | acc]}
          else
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp store_module?({:__aliases__, _meta, [:LemonCore, :Store]}, _aliases), do: true

  defp store_module?({:__aliases__, _meta, [name]}, aliases),
    do: MapSet.member?(aliases, name)

  defp store_module?(_target, _aliases), do: false

  defp resolve_table(table, _attributes) when is_atom(table), do: {:resolved, table}

  defp resolve_table({:@, _meta, [{name, _name_meta, _context}]}, attributes)
       when is_atom(name) do
    case attributes |> Map.get(name) |> resolve_attribute(attributes) do
      table when is_atom(table) -> {:resolved, table}
      _ -> :unresolved
    end
  end

  defp resolve_table(_table, _attributes), do: :unresolved

  defp resolve_attribute({:@, _meta, [{name, _name_meta, _context}]}, attributes)
       when is_atom(name),
       do: Map.get(attributes, name)

  defp resolve_attribute(value, _attributes), do: value

  defp bypass_issue(call, declared, relative) do
    table =
      case call.table do
        {:resolved, name} -> inspect(name)
        :unresolved -> "an unresolved table"
      end

    location = if call.line, do: " at line #{call.line}", else: ""

    %{
      code: :store_table_owner_bypass,
      message:
        "Store.Table owner declares #{inspect(declared)} but " <>
          "LemonCore.Store.#{call.function}/#{call.arity}#{location} accesses #{table}",
      path: relative
    }
  end
end
