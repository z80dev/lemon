defmodule CodingAgent.ToolRegistry do
  @moduledoc """
  Dynamic tool registry for managing available tools.

  This module provides a centralized registry for tools, allowing:
  - Registration of built-in tools
  - Loading of extension tools
  - Enabling/disabling tools per session
  - Tool lookup by name
  - Conflict detection with deterministic precedence

  ## Tool Precedence

  When multiple tools share the same name, the following precedence applies:

  1. **Built-in tools always win** - Core tools take priority over extension tools
  2. **Among extensions, first loaded wins** - Extensions are loaded in alphabetical
     order by module name, so earlier modules take precedence

  When a conflict is detected, a warning is logged with the tool name and the
  module that was shadowed.

  ## Usage

      # Get all enabled tools for a session
      tools = ToolRegistry.get_tools(cwd, session_opts)

      # Check if a tool is available
      ToolRegistry.has_tool?(cwd, "bash")

      # Get a specific tool
      {:ok, tool} = ToolRegistry.get_tool(cwd, "read")
  """

  require Logger

  alias CodingAgent.Extensions
  alias CodingAgent.Tools

  @type tool_name :: String.t()
  @type tool_opts :: keyword()

  # Built-in tools - order matters for tool description
  @builtin_tools [
    {:read, Tools.Read},
    {:write, Tools.Write},
    {:edit, Tools.Edit},
    {:patch, Tools.Patch},
    {:bash, Tools.Bash},
    {:grep, Tools.Grep},
    {:find, Tools.Find},
    {:ls, Tools.Ls},
    {:webfetch, Tools.WebFetch},
    {:websearch, Tools.WebSearch},
    {:todo, Tools.Todo},
    {:task, Tools.Task},
    {:extensions_status, Tools.ExtensionsStatus}
  ]

  @doc """
  Get all enabled tools for a working directory.

  Returns a list of AgentTool structs for all enabled tools.

  ## Parameters

    * `cwd` - Current working directory
    * `opts` - Options for tool configuration
      * `:disabled` - List of tool names to disable
      * `:enabled_only` - List of tool names to enable (disables all others)
      * `:include_extensions` - Whether to include extension tools (default: true)
      * `:extension_paths` - List of paths to search for extensions (default: uses `Extensions.load_default_extensions/1`)

  ## Returns

  List of `AgentCore.Types.AgentTool` structs.
  """
  @spec get_tools(String.t(), tool_opts()) :: [AgentCore.Types.AgentTool.t()]
  def get_tools(cwd, opts \\ []) do
    disabled = Keyword.get(opts, :disabled, [])
    enabled_only = Keyword.get(opts, :enabled_only, nil)
    include_extensions = Keyword.get(opts, :include_extensions, true)
    extension_paths = Keyword.get(opts, :extension_paths)

    # Get built-in tools with source tracking
    builtin =
      @builtin_tools
      |> Enum.map(fn {name, module} ->
        {Atom.to_string(name), module.tool(cwd, opts), {:builtin, module}}
      end)

    # Get extension tools with source tracking (using load_extensions_with_errors to capture failures)
    extension_tools =
      if include_extensions do
        paths =
          if extension_paths do
            extension_paths
          else
            [
              CodingAgent.Config.extensions_dir(),
              CodingAgent.Config.project_extensions_dir(cwd)
            ]
          end

        {:ok, extensions, _load_errors, _validation_errors} =
          Extensions.load_extensions_with_errors(paths)

        extensions = sort_extensions(extensions)

        Extensions.get_tools_with_source(extensions, cwd)
        |> Enum.map(fn {tool, ext_module} ->
          {tool.name, tool, {:extension, ext_module}}
        end)
      else
        []
      end

    # Merge tools with conflict detection
    all_tools = merge_tools_with_conflict_detection(builtin, extension_tools)

    # Filter based on enabled/disabled
    tools =
      all_tools
      |> filter_tools(disabled, enabled_only)
      |> Enum.map(fn {_name, tool, _source} -> tool end)

    # Apply approval wrapping if policy and context provided
    tool_policy = Keyword.get(opts, :tool_policy)
    approval_context = Keyword.get(opts, :approval_context)

    if tool_policy && approval_context do
      CodingAgent.ToolExecutor.wrap_all_with_approval(tools, tool_policy, approval_context)
    else
      tools
    end
  end

  @doc """
  Get a specific tool by name.

  ## Parameters

    * `cwd` - Current working directory
    * `name` - Tool name
    * `opts` - Tool options

  ## Returns

    * `{:ok, tool}` - If tool is found
    * `{:error, :not_found}` - If tool doesn't exist
  """
  @spec get_tool(String.t(), tool_name(), tool_opts()) ::
          {:ok, AgentCore.Types.AgentTool.t()} | {:error, :not_found}
  def get_tool(cwd, name, opts \\ []) when is_binary(name) do
    tools = get_tools(cwd, opts)

    case Enum.find(tools, fn tool -> tool.name == name end) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  @doc """
  Check if a tool is available.

  ## Parameters

    * `cwd` - Current working directory
    * `name` - Tool name

  ## Returns

  `true` if tool exists, `false` otherwise.
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

  ## Parameters

    * `cwd` - Current working directory
    * `opts` - Options

  ## Returns

  List of tool name strings.
  """
  @spec list_tool_names(String.t(), tool_opts()) :: [tool_name()]
  def list_tool_names(cwd, opts \\ []) do
    get_tools(cwd, opts)
    |> Enum.map(& &1.name)
  end

  @doc """
  Get tool descriptions for system prompt.

  ## Parameters

    * `cwd` - Current working directory
    * `opts` - Options

  ## Returns

  Formatted string with tool descriptions.
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

  ## Returns

  List of built-in tool name atoms.
  """
  @spec builtin_tool_names() :: [atom()]
  def builtin_tool_names do
    Enum.map(@builtin_tools, fn {name, _} -> name end)
  end

  @typedoc """
  A tool conflict report entry.

  - `:tool_name` - The conflicting tool name
  - `:winner` - Source that won (`:builtin` or `{:extension, module()}`)
  - `:shadowed` - List of sources that were shadowed
  """
  @type conflict_entry :: %{
          tool_name: String.t(),
          winner: :builtin | {:extension, module()},
          shadowed: [{:extension, module()}]
        }

  @typedoc """
  Complete tool conflict report.

  - `:conflicts` - List of conflict entries
  - `:total_tools` - Total number of tools available after conflict resolution
  - `:builtin_count` - Number of built-in tools
  - `:extension_count` - Number of extension tools (after shadowing)
  - `:shadowed_count` - Total number of shadowed tools
  - `:load_errors` - List of extension load errors (files that failed to compile/load)
  """
  @type conflict_report :: %{
          conflicts: [conflict_entry()],
          total_tools: non_neg_integer(),
          builtin_count: non_neg_integer(),
          extension_count: non_neg_integer(),
          shadowed_count: non_neg_integer(),
          load_errors: [Extensions.load_error()]
        }

  @doc """
  Get a report of tool name conflicts and extension load errors.

  Returns a structured report showing which tools conflict and how they
  are resolved, plus any extensions that failed to load. This is useful
  for plugin observability and debugging.

  ## Parameters

    * `cwd` - Current working directory
    * `opts` - Options (same as `get_tools/2`)

  ## Returns

  A map with conflict information:

    * `:conflicts` - List of conflict entries, each with:
      * `:tool_name` - The conflicting tool name
      * `:winner` - The source that won (`:builtin` or `{:extension, module}`)
      * `:shadowed` - List of `{:extension, module}` tuples that were shadowed
    * `:total_tools` - Total number of tools available
    * `:builtin_count` - Number of built-in tools
    * `:extension_count` - Number of extension tools (after shadowing)
    * `:shadowed_count` - Total number of shadowed tools
    * `:load_errors` - List of extension load errors, each with:
      * `:source_path` - Path to the file that failed to load
      * `:error` - The error reason
      * `:error_message` - Human-readable error message

  ## Examples

      report = ToolRegistry.tool_conflict_report(cwd)
      # => %{
      #   conflicts: [
      #     %{tool_name: "read", winner: :builtin, shadowed: [{:extension, MyExtension}]}
      #   ],
      #   total_tools: 16,
      #   builtin_count: 15,
      #   extension_count: 1,
      #   shadowed_count: 1,
      #   load_errors: [
      #     %{source_path: "/path/to/bad.ex", error: %CompileError{}, error_message: "..."}
      #   ]
      # }
  """
  @spec tool_conflict_report(String.t(), tool_opts()) :: conflict_report()
  def tool_conflict_report(cwd, opts \\ []) do
    include_extensions = Keyword.get(opts, :include_extensions, true)
    extension_paths = Keyword.get(opts, :extension_paths)

    # Get built-in tools with source tracking
    builtin =
      @builtin_tools
      |> Enum.map(fn {name, module} ->
        {Atom.to_string(name), module.tool(cwd, opts), {:builtin, module}}
      end)

    # Get extension tools with source tracking (using load_extensions_with_errors to capture failures)
    {extension_tools, load_errors} =
      if include_extensions do
        paths =
          if extension_paths do
            extension_paths
          else
            [
              CodingAgent.Config.extensions_dir(),
              CodingAgent.Config.project_extensions_dir(cwd)
            ]
          end

        {:ok, extensions, errors, _validation_errors} =
          Extensions.load_extensions_with_errors(paths)

        extensions = sort_extensions(extensions)

        tools =
          Extensions.get_tools_with_source(extensions, cwd)
          |> Enum.map(fn {tool, ext_module} ->
            {tool.name, tool, {:extension, ext_module}}
          end)

        {tools, errors}
      else
        {[], []}
      end

    # Analyze conflicts without logging
    {resolved_tools, conflicts} = analyze_conflicts(builtin, extension_tools)

    builtin_count = length(builtin)
    extension_count = length(resolved_tools) - builtin_count
    shadowed_count = Enum.reduce(conflicts, 0, fn c, acc -> acc + length(c.shadowed) end)

    %{
      conflicts: conflicts,
      total_tools: length(resolved_tools),
      builtin_count: builtin_count,
      extension_count: extension_count,
      shadowed_count: shadowed_count,
      load_errors: load_errors
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Merge builtin and extension tools, detecting and warning about conflicts.
  # Builtin tools always take precedence over extension tools.
  # Among extension tools, the first one loaded wins (alphabetical by module name).
  @spec merge_tools_with_conflict_detection(
          [{String.t(), AgentCore.Types.AgentTool.t(), {:builtin, module()}}],
          [{String.t(), AgentCore.Types.AgentTool.t(), {:extension, module()}}]
        ) :: [{String.t(), AgentCore.Types.AgentTool.t(), {:builtin | :extension, module()}}]
  defp merge_tools_with_conflict_detection(builtin_tools, extension_tools) do
    builtin_names =
      builtin_tools
      |> Enum.map(fn {name, _tool, _source} -> name end)
      |> MapSet.new()

    # Process extension tools, detecting conflicts
    {valid_extension_tools, _seen} =
      Enum.reduce(extension_tools, {[], builtin_names}, fn {name, tool, source}, {acc, seen} ->
        cond do
          # Conflict with builtin tool
          MapSet.member?(builtin_names, name) ->
            {:extension, ext_module} = source

            Logger.warning(
              "Tool name conflict: extension tool '#{name}' from #{inspect(ext_module)} " <>
                "is shadowed by built-in tool"
            )

            {acc, seen}

          # Conflict with another extension tool already processed
          MapSet.member?(seen, name) ->
            {:extension, ext_module} = source

            Logger.warning(
              "Tool name conflict: extension tool '#{name}' from #{inspect(ext_module)} " <>
                "is shadowed by earlier extension"
            )

            {acc, seen}

          # No conflict, add the tool
          true ->
            {[{name, tool, source} | acc], MapSet.put(seen, name)}
        end
      end)

    # Return builtin tools followed by valid extension tools (in reverse to preserve order)
    builtin_tools ++ Enum.reverse(valid_extension_tools)
  end

  defp filter_tools(tools, disabled, nil) do
    # Filter out disabled tools
    disabled_set = MapSet.new(disabled, &to_string/1)

    Enum.reject(tools, fn {name, _tool, _source} ->
      MapSet.member?(disabled_set, name)
    end)
  end

  defp filter_tools(tools, _disabled, enabled_only) do
    # Only include explicitly enabled tools
    enabled_set = MapSet.new(enabled_only, &to_string/1)

    Enum.filter(tools, fn {name, _tool, _source} ->
      MapSet.member?(enabled_set, name)
    end)
  end

  defp sort_extensions(extensions) do
    Enum.sort_by(extensions, fn module -> Atom.to_string(module) end)
  end

  # Analyze conflicts and return {resolved_tools, conflicts} without logging.
  # Used by tool_conflict_report/2 for structured conflict reporting.
  @spec analyze_conflicts(
          [{String.t(), AgentCore.Types.AgentTool.t(), {:builtin, module()}}],
          [{String.t(), AgentCore.Types.AgentTool.t(), {:extension, module()}}]
        ) :: {
          [{String.t(), AgentCore.Types.AgentTool.t(), {:builtin | :extension, module()}}],
          [conflict_entry()]
        }
  defp analyze_conflicts(builtin_tools, extension_tools) do
    builtin_names =
      builtin_tools
      |> Enum.map(fn {name, _tool, _source} -> name end)
      |> MapSet.new()

    # Group extension tools by name for conflict tracking
    ext_by_name =
      Enum.group_by(extension_tools, fn {name, _tool, _source} -> name end)

    # Process extension tools, tracking conflicts
    {valid_extension_tools, conflicts, _seen} =
      Enum.reduce(extension_tools, {[], [], builtin_names}, fn {name, tool, source},
                                                               {acc, conflicts, seen} ->
        cond do
          # Conflict with builtin tool
          MapSet.member?(builtin_names, name) ->
            existing_conflict = Enum.find(conflicts, fn c -> c.tool_name == name end)

            if existing_conflict do
              # Already recorded this builtin conflict, add to shadowed list
              updated =
                Enum.map(conflicts, fn c ->
                  if c.tool_name == name do
                    %{c | shadowed: [source | c.shadowed]}
                  else
                    c
                  end
                end)

              {acc, updated, seen}
            else
              # First time seeing this builtin conflict
              conflict = %{
                tool_name: name,
                winner: :builtin,
                shadowed: [source]
              }

              {acc, [conflict | conflicts], seen}
            end

          # Conflict with another extension tool already processed
          MapSet.member?(seen, name) ->
            # Find the winner (first extension with this name)
            {_winner_name, _winner_tool, winner_source} =
              Enum.find(ext_by_name[name], fn {_, _, s} ->
                {:extension, winner_mod} = s
                {:extension, current_mod} = source
                winner_mod != current_mod
              end) || {name, tool, source}

            existing_conflict = Enum.find(conflicts, fn c -> c.tool_name == name end)

            if existing_conflict do
              # Already recorded this extension conflict, add to shadowed list
              updated =
                Enum.map(conflicts, fn c ->
                  if c.tool_name == name do
                    %{c | shadowed: [source | c.shadowed]}
                  else
                    c
                  end
                end)

              {acc, updated, seen}
            else
              # First time seeing this extension-vs-extension conflict
              conflict = %{
                tool_name: name,
                winner: winner_source,
                shadowed: [source]
              }

              {acc, [conflict | conflicts], seen}
            end

          # No conflict, add the tool
          true ->
            {[{name, tool, source} | acc], conflicts, MapSet.put(seen, name)}
        end
      end)

    # Return builtin tools followed by valid extension tools (in reverse to preserve order)
    resolved = builtin_tools ++ Enum.reverse(valid_extension_tools)
    {resolved, Enum.reverse(conflicts)}
  end
end
