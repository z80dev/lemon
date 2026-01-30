defmodule CodingAgent.ToolRegistry do
  @moduledoc """
  Dynamic tool registry for managing available tools.

  This module provides a centralized registry for tools, allowing:
  - Registration of built-in tools
  - Loading of extension tools
  - Enabling/disabling tools per session
  - Tool lookup by name

  ## Usage

      # Get all enabled tools for a session
      tools = ToolRegistry.get_tools(cwd, session_opts)

      # Check if a tool is available
      ToolRegistry.has_tool?(cwd, "bash")

      # Get a specific tool
      {:ok, tool} = ToolRegistry.get_tool(cwd, "read")
  """

  alias CodingAgent.Extensions
  alias CodingAgent.Tools

  @type tool_name :: String.t()
  @type tool_opts :: keyword()

  # Built-in tools - order matters for tool description
  @builtin_tools [
    {:read, Tools.Read},
    {:write, Tools.Write},
    {:edit, Tools.Edit},
    {:multiedit, Tools.MultiEdit},
    {:glob, Tools.Glob},
    {:grep, Tools.Grep},
    {:find, Tools.Find},
    {:ls, Tools.Ls},
    {:bash, Tools.Bash},
    {:task, Tools.Task},
    {:patch, Tools.Patch},
    {:todoread, Tools.TodoRead},
    {:todowrite, Tools.TodoWrite},
    {:webfetch, Tools.WebFetch},
    {:websearch, Tools.WebSearch}
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

  ## Returns

  List of `AgentCore.Types.AgentTool` structs.
  """
  @spec get_tools(String.t(), tool_opts()) :: [AgentCore.Types.AgentTool.t()]
  def get_tools(cwd, opts \\ []) do
    disabled = Keyword.get(opts, :disabled, [])
    enabled_only = Keyword.get(opts, :enabled_only, nil)
    include_extensions = Keyword.get(opts, :include_extensions, true)

    # Get built-in tools
    builtin =
      @builtin_tools
      |> Enum.map(fn {name, module} ->
        {Atom.to_string(name), module.tool(cwd, opts)}
      end)

    # Get extension tools
    extension_tools =
      if include_extensions do
        case Extensions.load_default_extensions(cwd) do
          {:ok, extensions} ->
            Extensions.get_tools(extensions, cwd)
            |> Enum.map(fn tool -> {tool.name, tool} end)

          _ ->
            []
        end
      else
        []
      end

    # Combine all tools
    all_tools = builtin ++ extension_tools

    # Filter based on enabled/disabled
    all_tools
    |> filter_tools(disabled, enabled_only)
    |> Enum.map(fn {_name, tool} -> tool end)
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

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp filter_tools(tools, disabled, nil) do
    # Filter out disabled tools
    disabled_set = MapSet.new(disabled, &to_string/1)

    Enum.reject(tools, fn {name, _tool} ->
      MapSet.member?(disabled_set, name)
    end)
  end

  defp filter_tools(tools, _disabled, enabled_only) do
    # Only include explicitly enabled tools
    enabled_set = MapSet.new(enabled_only, &to_string/1)

    Enum.filter(tools, fn {name, _tool} ->
      MapSet.member?(enabled_set, name)
    end)
  end
end
