defmodule CodingAgent.ToolRegistry do
  @moduledoc """
  Dynamic tool registry for managing available tools.

  Precedence order is deterministic:

  1. Built-in tools
  2. WASM tools
  3. Extension tools
  """

  require Logger

  alias AgentCore.Types.AgentTool
  alias CodingAgent.Extensions
  alias CodingAgent.ToolExecutor
  alias CodingAgent.ToolPolicy
  alias CodingAgent.Tools
  alias CodingAgent.Wasm.Policy, as: WasmPolicy

  @type tool_name :: String.t()
  @type tool_opts :: keyword()
  @type source_meta :: map()

  @type tool_source ::
          :builtin
          | {:wasm, source_meta()}
          | {:extension, module()}

  @type tool_tuple :: {String.t(), AgentTool.t(), tool_source()}

  @extension_cache_table :coding_agent_tool_registry_extension_cache

  @builtin_tools [
    {:read, Tools.Read},
    {:memory_topic, Tools.MemoryTopic},
    {:write, Tools.Write},
    {:edit, Tools.Edit},
    {:patch, Tools.Patch},
    {:bash, Tools.Bash},
    {:grep, Tools.Grep},
    {:find, Tools.Find},
    {:ls, Tools.Ls},
    {:browser, Tools.Browser},
    {:webfetch, Tools.WebFetch},
    {:websearch, Tools.WebSearch},
    {:todo, Tools.Todo},
    {:task, Tools.Task},
    {:agent, Tools.Agent},
    {:tool_auth, Tools.ToolAuth},
    {:extensions_status, Tools.ExtensionsStatus},
    {:post_to_x, Tools.PostToX},
    {:get_x_mentions, Tools.GetXMentions},
    {:hashline_edit, Tools.HashlineEdit}
  ]

  @doc """
  Get all enabled tools for a working directory.
  """
  @spec get_tools(String.t(), tool_opts()) :: [AgentTool.t()]
  def get_tools(cwd, opts \\ []) do
    disabled = Keyword.get(opts, :disabled, [])
    enabled_only = Keyword.get(opts, :enabled_only, nil)
    include_extensions = Keyword.get(opts, :include_extensions, true)

    builtin = builtin_tool_tuples(cwd, opts)
    wasm_tools = normalize_wasm_tools(Keyword.get(opts, :wasm_tools, []))

    extension_tools =
      if include_extensions do
        {extensions, _load_errors} = extension_inventory(cwd, opts)

        Extensions.get_tools_with_source(extensions, cwd)
        |> Enum.map(fn {tool, ext_module} ->
          {tool.name, tool, {:extension, ext_module}}
        end)
        # Keep tool ordering deterministic for stable prompts / prompt caching.
        |> Enum.sort_by(fn {name, _tool, {:extension, ext_module}} ->
          {name, Atom.to_string(ext_module)}
        end)
      else
        []
      end

    {resolved_tools, _conflicts} = resolve_tools(builtin, wasm_tools, extension_tools, true)

    tools =
      resolved_tools
      |> filter_tools(disabled, enabled_only)
      |> filter_policy_blocked(Keyword.get(opts, :tool_policy))
      |> maybe_wrap_approval(
        Keyword.get(opts, :tool_policy),
        Keyword.get(opts, :approval_context)
      )
      |> Enum.map(fn {_name, tool, _source} -> tool end)

    tools
  end

  @doc """
  Get a specific tool by name.
  """
  @spec get_tool(String.t(), tool_name(), tool_opts()) ::
          {:ok, AgentTool.t()} | {:error, :not_found}
  def get_tool(cwd, name, opts \\ []) when is_binary(name) do
    tools = get_tools(cwd, opts)

    case Enum.find(tools, fn tool -> tool.name == name end) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  @doc """
  Check if a tool is available.
  """
  @spec has_tool?(String.t(), tool_name()) :: boolean()
  def has_tool?(cwd, name) when is_binary(name) do
    case get_tool(cwd, name) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  List all available tool names.
  """
  @spec list_tool_names(String.t(), tool_opts()) :: [tool_name()]
  def list_tool_names(cwd, opts \\ []) do
    get_tools(cwd, opts)
    |> Enum.map(& &1.name)
  end

  @doc """
  Get tool descriptions for system prompt.
  """
  @spec format_tool_descriptions(String.t(), tool_opts()) :: String.t()
  def format_tool_descriptions(cwd, opts \\ []) do
    get_tools(cwd, opts)
    |> Enum.map(fn tool ->
      "- #{tool.name}: #{tool.description}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Get the list of built-in tool names.
  """
  @spec builtin_tool_names() :: [atom()]
  def builtin_tool_names do
    Enum.map(@builtin_tools, fn {name, _} -> name end)
  end

  @doc """
  Prime the extension load cache for a cwd/path set.
  """
  @spec prime_extension_cache(String.t(), [String.t()], [module()], [Extensions.load_error()]) ::
          :ok
  def prime_extension_cache(cwd, extension_paths, extensions, load_errors \\ [])
      when is_list(extension_paths) and is_list(extensions) and is_list(load_errors) do
    key = cache_key(cwd, extension_paths)

    snapshot = %{
      extensions: sort_extensions(extensions),
      load_errors: load_errors,
      loaded_at: System.system_time(:millisecond)
    }

    cache_insert(key, snapshot)
    :ok
  end

  @doc """
  Invalidate all cached extension load data.
  """
  @spec invalidate_extension_cache() :: :ok
  def invalidate_extension_cache do
    cache_delete_all()
    :ok
  end

  @doc """
  Invalidate cached extension load data for a cwd.
  """
  @spec invalidate_extension_cache(String.t(), tool_opts()) :: :ok
  def invalidate_extension_cache(cwd, opts \\ []) do
    expanded_cwd = Path.expand(cwd)
    extension_paths = Keyword.get(opts, :extension_paths)

    case extension_paths do
      paths when is_list(paths) ->
        cache_delete(cache_key(expanded_cwd, paths))

      _ ->
        cache_tab2list()
        |> Enum.each(fn {{cached_cwd, _paths} = key, _snapshot} ->
          if cached_cwd == expanded_cwd do
            cache_delete(key)
          end
        end)
    end

    :ok
  end

  @typedoc """
  A tool conflict report entry.

  - `:tool_name` - The conflicting tool name
  - `:winner` - Source that won (`:builtin`, `{:wasm, name_or_path}`, or `{:extension, module()}`)
  - `:shadowed` - List of shadowed sources
  """
  @type conflict_entry :: %{
          tool_name: String.t(),
          winner: :builtin | {:wasm, String.t()} | {:extension, module()},
          shadowed: [{:wasm, String.t()} | {:extension, module()}]
        }

  @typedoc """
  Complete tool conflict report.
  """
  @type conflict_report :: %{
          conflicts: [conflict_entry()],
          total_tools: non_neg_integer(),
          builtin_count: non_neg_integer(),
          wasm_count: non_neg_integer(),
          extension_count: non_neg_integer(),
          shadowed_count: non_neg_integer(),
          load_errors: [Extensions.load_error()],
          wasm: map() | nil
        }

  @doc """
  Get a report of tool name conflicts and extension load errors.
  """
  @spec tool_conflict_report(String.t(), tool_opts()) :: conflict_report()
  def tool_conflict_report(cwd, opts \\ []) do
    include_extensions = Keyword.get(opts, :include_extensions, true)

    builtin = builtin_tool_tuples(cwd, opts)
    wasm_tools = normalize_wasm_tools(Keyword.get(opts, :wasm_tools, []))

    {extension_tools, load_errors} =
      if include_extensions do
        {extensions, errors} = extension_inventory(cwd, opts)

        tools =
          Extensions.get_tools_with_source(extensions, cwd)
          |> Enum.map(fn {tool, ext_module} ->
            {tool.name, tool, {:extension, ext_module}}
          end)

        {tools, errors}
      else
        {[], []}
      end

    {resolved_tools, conflicts} = resolve_tools(builtin, wasm_tools, extension_tools, false)

    wasm_count = source_count(resolved_tools, :wasm)
    builtin_count = source_count(resolved_tools, :builtin)
    extension_count = source_count(resolved_tools, :extension)

    shadowed_count = Enum.reduce(conflicts, 0, fn c, acc -> acc + length(c.shadowed) end)

    %{
      conflicts: conflicts,
      total_tools: length(resolved_tools),
      builtin_count: builtin_count,
      wasm_count: wasm_count,
      extension_count: extension_count,
      shadowed_count: shadowed_count,
      load_errors: load_errors,
      wasm: Keyword.get(opts, :wasm_status)
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp builtin_tool_tuples(cwd, opts) do
    @builtin_tools
    |> Enum.map(fn {name, module} ->
      {Atom.to_string(name), module.tool(cwd, opts), :builtin}
    end)
  end

  @spec extension_inventory(String.t(), tool_opts()) :: {[module()], [Extensions.load_error()]}
  defp extension_inventory(cwd, opts) do
    extension_paths = resolve_extension_paths(cwd, opts)
    key = cache_key(cwd, extension_paths)

    case lookup_extension_inventory(key) do
      {:ok, %{extensions: extensions, load_errors: load_errors}} ->
        {extensions, load_errors}

      :error ->
        {:ok, extensions, load_errors, _validation_errors} =
          Extensions.load_extensions_with_errors(extension_paths)

        prime_extension_cache(cwd, extension_paths, extensions, load_errors)

        {sort_extensions(extensions), load_errors}
    end
  end

  defp lookup_extension_inventory(key) do
    case cache_lookup(key) do
      [{^key, snapshot}] -> {:ok, snapshot}
      [] -> :error
    end
  end

  defp resolve_extension_paths(cwd, opts) do
    case Keyword.get(opts, :extension_paths) do
      paths when is_list(paths) ->
        paths

      _ ->
        [
          CodingAgent.Config.extensions_dir(),
          CodingAgent.Config.project_extensions_dir(cwd)
        ]
    end
  end

  defp cache_key(cwd, extension_paths) do
    {Path.expand(cwd), normalize_paths(extension_paths)}
  end

  defp normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
  end

  defp ensure_cache_table do
    case :ets.whereis(@extension_cache_table) do
      :undefined ->
        try do
          :ets.new(@extension_cache_table, [:set, :public, :named_table])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp cache_insert(key, snapshot) do
    with_cache_table(fn ->
      :ets.insert(@extension_cache_table, {key, snapshot})
    end)
  end

  defp cache_delete_all do
    with_cache_table(fn ->
      :ets.delete_all_objects(@extension_cache_table)
    end)
  end

  defp cache_delete(key) do
    with_cache_table(fn ->
      :ets.delete(@extension_cache_table, key)
    end)
  end

  defp cache_tab2list do
    with_cache_table(fn ->
      :ets.tab2list(@extension_cache_table)
    end)
  end

  defp cache_lookup(key) do
    with_cache_table(fn ->
      :ets.lookup(@extension_cache_table, key)
    end)
  end

  defp with_cache_table(operation, attempts_left \\ 2) do
    ensure_cache_table()

    try do
      operation.()
    rescue
      ArgumentError ->
        if attempts_left > 1 do
          with_cache_table(operation, attempts_left - 1)
        else
          reraise ArgumentError, __STACKTRACE__
        end
    end
  end

  @spec resolve_tools([tool_tuple()], [tool_tuple()], [tool_tuple()], boolean()) ::
          {[tool_tuple()], [conflict_entry()]}
  defp resolve_tools(builtin_tools, wasm_tools, extension_tools, log_conflicts?) do
    initial_winners =
      builtin_tools
      |> Enum.map(fn {name, _tool, source} -> {name, source} end)
      |> Map.new()

    {rev_resolved, _winners, conflicts} =
      Enum.reduce([wasm_tools, extension_tools], {Enum.reverse(builtin_tools), initial_winners, %{}}, fn tools,
                                                                                           {resolved_acc,
                                                                                            winners_acc,
                                                                                            conflicts_acc} ->
        Enum.reduce(tools, {resolved_acc, winners_acc, conflicts_acc}, fn {name, tool, source},
                                                                          {resolved, winners,
                                                                           conflicts} ->
          case Map.get(winners, name) do
            nil ->
              # Prepend for O(1) instead of O(n) append
              {[{name, tool, source} | resolved], Map.put(winners, name, source), conflicts}

            winner_source ->
              if log_conflicts? do
                log_conflict(name, winner_source, source)
              end

              {resolved, winners, add_conflict(conflicts, name, winner_source, source)}
          end
        end)
      end)

    # Reverse to restore original order
    resolved = Enum.reverse(rev_resolved)

    conflict_entries =
      conflicts
      |> Map.values()
      |> Enum.sort_by(& &1.tool_name)
      |> Enum.map(&serialize_conflict_entry/1)

    {resolved, conflict_entries}
  end

  defp add_conflict(conflicts, tool_name, winner_source, shadowed_source) do
    Map.update(
      conflicts,
      tool_name,
      %{tool_name: tool_name, winner: winner_source, shadowed: [shadowed_source]},
      fn existing ->
        # Prepend for O(1) instead of O(n) append - order doesn't matter for conflicts
        %{existing | shadowed: [shadowed_source | existing.shadowed]}
      end
    )
  end

  defp serialize_conflict_entry(%{tool_name: tool_name, winner: winner, shadowed: shadowed}) do
    %{
      tool_name: tool_name,
      winner: serialize_source(winner),
      shadowed:
        shadowed
        |> Enum.map(&serialize_source/1)
        |> Enum.reject(&(&1 == :builtin))
    }
  end

  defp serialize_source(:builtin), do: :builtin

  defp serialize_source({:extension, mod}), do: {:extension, mod}

  defp serialize_source({:wasm, meta}) do
    {:wasm, wasm_identity(meta)}
  end

  defp serialize_source(_), do: :builtin

  defp wasm_identity(meta) when is_map(meta) do
    Map.get(meta, :path) || Map.get(meta, "path") || Map.get(meta, :name) || Map.get(meta, "name") ||
      "unknown"
  end

  defp wasm_identity(other), do: to_string(other)

  defp log_conflict(name, winner_source, shadowed_source) do
    Logger.warning(
      "Tool name conflict: '#{name}' from #{source_label(shadowed_source)} is shadowed by #{source_label(winner_source)}"
    )
  end

  defp source_label(:builtin), do: "built-in"
  defp source_label({:extension, module}), do: "extension #{inspect(module)}"

  defp source_label({:wasm, meta}),
    do:
      "wasm #{Map.get(meta, :path) || Map.get(meta, "path") || Map.get(meta, :name) || Map.get(meta, "name") || "unknown"}"

  defp source_label(_), do: "unknown"

  defp source_count(tools, :builtin) do
    Enum.count(tools, fn {_name, _tool, source} -> source == :builtin end)
  end

  defp source_count(tools, :wasm) do
    Enum.count(tools, fn {_name, _tool, source} -> match?({:wasm, _}, source) end)
  end

  defp source_count(tools, :extension) do
    Enum.count(tools, fn {_name, _tool, source} -> match?({:extension, _}, source) end)
  end

  defp filter_tools(tools, disabled, nil) do
    disabled_set = MapSet.new(disabled, &to_string/1)

    Enum.reject(tools, fn {name, _tool, _source} ->
      MapSet.member?(disabled_set, name)
    end)
  end

  defp filter_tools(tools, _disabled, enabled_only) do
    enabled_set = MapSet.new(enabled_only, &to_string/1)

    Enum.filter(tools, fn {name, _tool, _source} ->
      MapSet.member?(enabled_set, name)
    end)
  end

  defp filter_policy_blocked(tools, nil), do: tools

  defp filter_policy_blocked(tools, tool_policy) do
    Enum.filter(tools, fn {name, _tool, _source} ->
      ToolPolicy.allowed?(tool_policy, name)
    end)
  end

  defp maybe_wrap_approval(tools, nil, _approval_context), do: tools
  defp maybe_wrap_approval(tools, _tool_policy, nil), do: tools

  defp maybe_wrap_approval(tools, tool_policy, approval_context) do
    Enum.map(tools, fn {name, tool, source} = tuple ->
      requires_approval =
        ToolPolicy.requires_approval?(tool_policy, name) or
          wasm_default_requires_approval?(tool_policy, name, source)

      if requires_approval do
        {name, force_wrap_approval(tool, name, approval_context), elem(tuple, 2)}
      else
        tuple
      end
    end)
  end

  defp wasm_default_requires_approval?(tool_policy, tool_name, {:wasm, meta}) do
    WasmPolicy.requires_approval?(tool_policy, tool_name, meta)
  end

  defp wasm_default_requires_approval?(_tool_policy, _tool_name, _source), do: false

  defp force_wrap_approval(%AgentTool{} = tool, tool_name, approval_context) do
    original_execute = tool.execute

    wrapped_execute = fn tool_call_id, params, signal, on_update ->
      ToolExecutor.execute_with_approval(
        tool_name,
        params,
        fn -> original_execute.(tool_call_id, params, signal, on_update) end,
        approval_context
      )
    end

    %{tool | execute: wrapped_execute}
  end

  defp normalize_wasm_tools(nil), do: []

  defp normalize_wasm_tools(tools) when is_list(tools) do
    tools
    |> Enum.flat_map(fn
      {name, %AgentTool{} = tool, {:wasm, meta}} when is_binary(name) and is_map(meta) ->
        [{name, tool, {:wasm, meta}}]

      %{name: name, tool: %AgentTool{} = tool, metadata: meta}
      when is_binary(name) and is_map(meta) ->
        [{name, tool, {:wasm, meta}}]

      _ ->
        []
    end)
    # Keep tool ordering deterministic for stable prompts / prompt caching.
    |> Enum.sort_by(fn {name, _tool, {:wasm, meta}} ->
      {name, wasm_identity(meta)}
    end)
  end

  defp normalize_wasm_tools(_), do: []

  defp sort_extensions(extensions) do
    Enum.sort_by(extensions, fn module -> Atom.to_string(module) end)
  end
end
