defmodule LemonCore.Quality.StoreTableOwnershipCheck do
  @moduledoc """
  AST analysis for modules that opt into `LemonCore.Store.Table` ownership.

  The incremental rule leaves legacy non-owner wrappers to existing migration
  checks. Once a module declares tables, however, every recognized generic
  Store call must resolve to one of those exact names. Aliases, module
  attributes, `apply/3`, and both default-server and explicit-server arities
  count.
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
    compare_and_delete: %{3 => 0, 4 => 1},
    fetch_all: %{1 => 0, 2 => 1},
    register_cached_table: %{1 => 0, 2 => 1},
    unregister_cached_table: %{1 => 0, 2 => 1}
  }

  @store_table_entry_arguments %{
    compare_and_delete_many: %{1 => 0, 2 => 1}
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

    case declared_store_tables(body, attributes, aliases) do
      :not_an_owner ->
        []

      {:ok, declared} ->
        body
        |> generic_store_calls(attributes, aliases)
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
        {:@, meta, [{name, name_meta, [value]}]} = node, acc when is_atom(name) ->
          assignment = {source_location(meta, name_meta), value}
          {node, Map.update(acc, name, [assignment], &[assignment | &1])}

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  defp store_aliases(body) do
    {_ast, aliases} =
      Macro.prewalk(body, %{}, fn
        {:alias, meta, args} = node, acc ->
          {node, collect_store_alias(args, source_location(meta), acc)}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp collect_store_alias([{:__aliases__, _meta, segments} | opts], location, acc)
       when is_list(segments) do
    if Enum.all?(segments, &is_atom/1) do
      default = List.last(segments)
      put_store_alias(acc, alias_name(opts, default), alias_kind(segments), location)
    else
      acc
    end
  end

  defp collect_store_alias(
         [
           {{:., _dot_meta, [{:__aliases__, _base_meta, base}, :{}]}, _call_meta, children}
         ],
         location,
         acc
       )
       when is_list(base) do
    if Enum.all?(base, &is_atom/1) do
      Enum.reduce(children, acc, fn
        {:__aliases__, _meta, child}, found when is_list(child) ->
          if Enum.all?(child, &is_atom/1) do
            put_store_alias(
              found,
              List.last(child),
              alias_kind(base ++ child),
              location
            )
          else
            found
          end

        _, found ->
          found
      end)
    else
      acc
    end
  end

  defp collect_store_alias(_args, _location, acc), do: acc

  defp alias_name([opts], default) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _meta, [name]} when is_atom(name) -> name
      _ -> default
    end
  end

  defp alias_name(_opts, default), do: default

  defp alias_kind([:LemonCore, :Store]), do: :store
  defp alias_kind([:LemonCore, :Store, :Table]), do: :table
  defp alias_kind(_segments), do: :other

  defp put_store_alias(aliases, name, kind, location) when is_atom(name) do
    binding = {location, kind}
    Map.update(aliases, name, [binding], &[binding | &1])
  end

  defp declared_store_tables(body, attributes, aliases) do
    {_ast, declarations} =
      Macro.prewalk(body, [], fn
        {:use, meta, [target, opts]} = node, acc when is_list(opts) ->
          location = source_location(meta)

          if store_table_module?(target, aliases, location) do
            {node, [{Keyword.get(opts, :tables), source_location(meta)} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    case declarations do
      [] ->
        :not_an_owner

      [{declaration, location}] ->
        case resolve_attribute(declaration, attributes, location) do
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

  defp store_table_module?(
         {:__aliases__, _meta, [:LemonCore, :Store, :Table]},
         _aliases,
         _location
       ),
       do: true

  defp store_table_module?({:__aliases__, _meta, [name]}, aliases, location),
    do: alias_resolves_to?(aliases, name, :table, location)

  defp store_table_module?(_target, _aliases, _location), do: false

  defp generic_store_calls(body, attributes, aliases) do
    {_ast, calls} =
      Macro.prewalk(body, [], fn
        {:apply, call_meta, [target, function, arguments]} = node, acc ->
          location = source_location(call_meta)

          calls =
            apply_store_calls(target, function, arguments, attributes, aliases, location)

          {node, Enum.reverse(calls) ++ acc}

        {{:., dot_meta, [apply_target, :apply]}, call_meta, [target, function, arguments]} =
            node,
            acc ->
          location = source_location(call_meta, dot_meta)

          calls =
            if kernel_apply_module?(apply_target) do
              apply_store_calls(target, function, arguments, attributes, aliases, location)
            else
              []
            end

          {node, Enum.reverse(calls) ++ acc}

        {{:., dot_meta, [target, function]}, call_meta, args} = node, acc
        when is_atom(function) and is_list(args) ->
          location = source_location(call_meta, dot_meta)

          calls =
            if store_module_expression?(target, attributes, aliases, location) do
              calls_for(function, args, attributes, location, false)
            else
              []
            end

          {node, Enum.reverse(calls) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp apply_store_calls(target, function, arguments, attributes, aliases, location) do
    if store_module_expression?(target, attributes, aliases, location) do
      resolved_function = resolve_attribute(function, attributes, location)
      resolved_arguments = resolve_attribute(arguments, attributes, location)

      cond do
        is_atom(resolved_function) and is_list(resolved_arguments) ->
          calls_for(resolved_function, resolved_arguments, attributes, location, true)

        known_store_operation?(resolved_function) ->
          [unresolved_apply_call(resolved_function, location)]

        is_atom(resolved_function) ->
          []

        true ->
          [unresolved_apply_call(:dynamic, location)]
      end
    else
      []
    end
  end

  defp calls_for(function, args, attributes, location, via_apply) do
    arity = length(args)

    case get_in(@store_table_arguments, [function, arity]) do
      table_index when is_integer(table_index) ->
        [
          store_call(
            function,
            arity,
            resolve_table(Enum.at(args, table_index), attributes, location),
            location,
            via_apply
          )
        ]

      nil ->
        calls_for_entry_list(function, args, attributes, location, via_apply)
    end
  end

  defp calls_for_entry_list(function, args, attributes, location, via_apply) do
    case get_in(@store_table_entry_arguments, [function, length(args)]) do
      entries_index when is_integer(entries_index) ->
        args
        |> Enum.at(entries_index)
        |> resolve_entry_tables(attributes, location)
        |> Enum.map(&store_call(function, length(args), &1, location, via_apply))

      nil ->
        []
    end
  end

  defp resolve_entry_tables(entries, attributes, location) do
    case resolve_attribute(entries, attributes, location) do
      entries when is_list(entries) ->
        Enum.map(entries, fn
          {:{}, _meta, [table, _key, _expected]} ->
            resolve_table(table, attributes, location)

          {table, _key, _expected} ->
            resolve_table(table, attributes, location)

          _other ->
            :unresolved
        end)

      _other ->
        [:unresolved]
    end
  end

  defp store_call(function, arity, table, location, via_apply) do
    %{
      function: function,
      arity: arity,
      table: table,
      line: elem(location, 0),
      via_apply: via_apply
    }
  end

  defp unresolved_apply_call(function, location) do
    %{
      function: function,
      arity: :unknown,
      table: :unresolved,
      line: elem(location, 0),
      via_apply: true
    }
  end

  defp known_store_operation?(function) when is_atom(function) do
    Map.has_key?(@store_table_arguments, function) or
      Map.has_key?(@store_table_entry_arguments, function)
  end

  defp known_store_operation?(_function), do: false

  defp kernel_apply_module?({:__aliases__, _meta, [:Kernel]}), do: true
  defp kernel_apply_module?(:erlang), do: true
  defp kernel_apply_module?(_target), do: false

  defp store_module_expression?(target, attributes, aliases, location) do
    target
    |> resolve_attribute(attributes, location)
    |> store_module?(aliases, location)
  end

  defp store_module?({:__aliases__, _meta, [:LemonCore, :Store]}, _aliases, _location), do: true

  defp store_module?({:__aliases__, _meta, [name]}, aliases, location),
    do: alias_resolves_to?(aliases, name, :store, location)

  defp store_module?(_target, _aliases, _location), do: false

  defp alias_resolves_to?(aliases, name, expected, location) do
    aliases
    |> Map.get(name, [])
    |> Enum.filter(fn {alias_location, _kind} -> alias_location < location end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      {_alias_location, ^expected} -> true
      _other -> false
    end
  end

  defp resolve_table(table, _attributes, _location) when is_atom(table), do: {:resolved, table}

  defp resolve_table(
         {:@, _meta, [{name, _name_meta, _context}]} = attribute,
         attributes,
         location
       )
       when is_atom(name) do
    case resolve_attribute(attribute, attributes, location) do
      table when is_atom(table) -> {:resolved, table}
      _ -> :unresolved
    end
  end

  defp resolve_table(_table, _attributes, _location), do: :unresolved

  defp resolve_attribute(value, attributes, location),
    do: resolve_attribute(value, attributes, location, MapSet.new())

  defp resolve_attribute(
         {:@, _meta, [{name, _name_meta, _context}]},
         attributes,
         location,
         seen
       )
       when is_atom(name) do
    if MapSet.member?(seen, name) do
      nil
    else
      attributes
      |> Map.get(name, [])
      |> Enum.filter(fn {assignment_location, _value} -> assignment_location < location end)
      |> Enum.max_by(&elem(&1, 0), fn -> nil end)
      |> case do
        {assignment_location, value} ->
          resolve_attribute(
            value,
            attributes,
            assignment_location,
            MapSet.put(seen, name)
          )

        nil ->
          nil
      end
    end
  end

  defp resolve_attribute(value, _attributes, _location, _seen), do: value

  defp source_location(primary, fallback \\ []) do
    line = Keyword.get(primary, :line) || Keyword.get(fallback, :line) || 0
    column = Keyword.get(primary, :column) || Keyword.get(fallback, :column) || 0
    {line, column}
  end

  defp bypass_issue(call, declared, relative) do
    table =
      case call.table do
        {:resolved, name} -> inspect(name)
        :unresolved -> "an unresolved table"
      end

    location = if call.line, do: " at line #{call.line}", else: ""
    operation = operation_label(call)

    %{
      code: :store_table_owner_bypass,
      message:
        "Store.Table owner declares #{inspect(declared)} but " <>
          "#{operation}#{location} accesses #{table}",
      path: relative
    }
  end

  defp operation_label(%{function: :dynamic, via_apply: true}),
    do: "dynamic LemonCore.Store apply/3"

  defp operation_label(%{function: function, arity: :unknown, via_apply: true}),
    do: "LemonCore.Store.#{function} via apply/3"

  defp operation_label(%{function: function, arity: arity, via_apply: true}),
    do: "LemonCore.Store.#{function}/#{arity} via apply/3"

  defp operation_label(%{function: function, arity: arity}),
    do: "LemonCore.Store.#{function}/#{arity}"
end
