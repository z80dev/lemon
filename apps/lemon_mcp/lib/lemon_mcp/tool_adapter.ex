defmodule LemonMCP.ToolAdapter do
  @moduledoc """
  Adapter that converts between MCP tool format and Lemon CodingAgent tools.

  This module allows existing CodingAgent tools to be exposed via the MCP protocol,
  enabling external MCP clients to use Lemon's tool ecosystem.

  ## Usage

      # Create an adapter for a specific working directory
      adapter = LemonMCP.ToolAdapter.new("/path/to/project")

      # List available tools in MCP format
      tools = LemonMCP.ToolAdapter.list_tools(adapter)

      # Call a tool
      {:ok, result} = LemonMCP.ToolAdapter.call_tool(adapter, "read", %{"path" => "README.md"})

  """

  require Logger

  alias LemonMCP.Protocol

  defstruct [:cwd, :tool_opts, :tool_modules]

  @type t :: %__MODULE__{
          cwd: String.t(),
          tool_opts: keyword(),
          tool_modules: %{String.t() => module()}
        }

  # Mapping of tool names to their CodingAgent.Tools modules
  @builtin_tools %{
    "browser" => CodingAgent.Tools.Browser,
    "read" => CodingAgent.Tools.Read,
    "write" => CodingAgent.Tools.Write,
    "edit" => CodingAgent.Tools.Edit,
    "hashline_edit" => CodingAgent.Tools.HashlineEdit,
    "patch" => CodingAgent.Tools.Patch,
    "bash" => CodingAgent.Tools.Bash,
    "grep" => CodingAgent.Tools.Grep,
    "find" => CodingAgent.Tools.Find,
    "ls" => CodingAgent.Tools.Ls,
    "webfetch" => CodingAgent.Tools.WebFetch,
    "websearch" => CodingAgent.Tools.WebSearch,
    "todo" => CodingAgent.Tools.Todo,
    "task" => CodingAgent.Tools.Task,
    "agent" => CodingAgent.Tools.Agent,
    "tool_auth" => CodingAgent.Tools.ToolAuth,
    "extensions_status" => CodingAgent.Tools.ExtensionsStatus,
    "post_to_x" => CodingAgent.Tools.PostToX,
    "get_x_mentions" => CodingAgent.Tools.GetXMentions
  }

  @doc """
  Creates a new tool adapter for the given working directory.

  ## Options

    * `:tool_opts` - Options passed to CodingAgent tools (e.g., disabled tools)
    * `:include_tools` - List of tool names to include (default: all)
    * `:exclude_tools` - List of tool names to exclude

  """
  @spec new(String.t(), keyword()) :: t()
  def new(cwd, opts \\ []) do
    tool_opts = Keyword.get(opts, :tool_opts, [])
    include_tools = Keyword.get(opts, :include_tools, Map.keys(@builtin_tools))
    exclude_tools = Keyword.get(opts, :exclude_tools, [])

    # Build the tool modules map
    tool_modules =
      @builtin_tools
      |> Enum.filter(fn {name, _module} ->
        name in include_tools and name not in exclude_tools
      end)
      |> Map.new()

    %__MODULE__{
      cwd: cwd,
      tool_opts: tool_opts,
      tool_modules: tool_modules
    }
  end

  @doc """
  Lists all available tools in MCP format.
  """
  @spec list_tools(t()) :: [Protocol.Tool.t()]
  def list_tools(%__MODULE__{} = adapter) do
    adapter.tool_modules
    |> Enum.map(fn {name, module} ->
      case build_mcp_tool(adapter, name, module) do
        {:ok, tool} -> tool
        {:error, _reason} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Calls a tool by name with the given arguments.

  Returns the result as an MCP ToolCallResult.
  """
  @spec call_tool(t(), String.t(), map()) ::
          {:ok, Protocol.ToolCallResult.t()} | {:error, term()}
  def call_tool(%__MODULE__{} = adapter, name, arguments) when is_map(arguments) do
    case Map.get(adapter.tool_modules, name) do
      nil ->
        {:error, :unknown_tool}

      module ->
        execute_tool(adapter, module, arguments)
    end
  end

  @doc """
  Returns the list of available tool names.
  """
  @spec tool_names(t()) :: [String.t()]
  def tool_names(%__MODULE__{} = adapter) do
    Map.keys(adapter.tool_modules)
  end

  @doc """
  Checks if a tool is available.
  """
  @spec has_tool?(t(), String.t()) :: boolean()
  def has_tool?(%__MODULE__{} = adapter, name) do
    Map.has_key?(adapter.tool_modules, name)
  end

  # ============================================================================
  # Tool Provider Implementation
  # ============================================================================

  defmacro __using__(opts) do
    quote do
      @behaviour LemonMCP.Server

      @adapter LemonMCP.ToolAdapter.new(
                 Keyword.get(unquote(opts), :cwd, File.cwd!()),
                 Keyword.delete(unquote(opts), :cwd)
               )

      @impl true
      def list_tools do
        LemonMCP.ToolAdapter.list_tools(@adapter)
      end

      @impl true
      def call_tool(name, arguments) do
        LemonMCP.ToolAdapter.call_tool(@adapter, name, arguments)
      end
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp build_mcp_tool(adapter, name, module) do
    # Get the tool struct from CodingAgent
    tool = module.tool(adapter.cwd, adapter.tool_opts)

    # Convert parameters format
    input_schema = convert_parameters_to_schema(tool.parameters)

    mcp_tool = %Protocol.Tool{
      name: name,
      description: tool.description,
      inputSchema: input_schema
    }

    {:ok, mcp_tool}
  rescue
    error ->
      Logger.warning("Failed to build MCP tool for #{name}: #{inspect(error)}")
      {:error, :tool_build_failed}
  end

  defp convert_parameters_to_schema(parameters) when is_list(parameters) do
    properties =
      parameters
      |> Enum.map(fn param ->
        schema = %{
          "type" => map_parameter_type(param.type),
          "description" => param.description
        }

        # Add enum if present
        schema =
          if param.enum do
            Map.put(schema, "enum", param.enum)
          else
            schema
          end

        {param.name, schema}
      end)
      |> Map.new()

    required =
      parameters
      |> Enum.filter(fn param -> param.required end)
      |> Enum.map(fn param -> param.name end)

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required
    }
  end

  defp convert_parameters_to_schema(_), do: %{"type" => "object", "properties" => %{}}

  defp map_parameter_type(:string), do: "string"
  defp map_parameter_type(:integer), do: "integer"
  defp map_parameter_type(:number), do: "number"
  defp map_parameter_type(:boolean), do: "boolean"
  defp map_parameter_type(:array), do: "array"
  defp map_parameter_type(:object), do: "object"
  defp map_parameter_type(:enum), do: "string"
  defp map_parameter_type(_), do: "string"

  defp execute_tool(adapter, module, arguments) do
    # Get the tool definition
    tool = module.tool(adapter.cwd, adapter.tool_opts)

    # Build the tool call from arguments
    tool_call = build_tool_call(tool.name, arguments)

    # Execute the tool
    result = execute_tool_call(tool, tool_call, adapter)

    # Convert result to MCP format
    {:ok, result}
  rescue
    error ->
      Logger.error("Tool execution failed: #{inspect(error)}")

      error_result = %Protocol.ToolCallResult{
        content: [
          %{
            type: "text",
            text: "Error: #{Exception.message(error)}"
          }
        ],
        isError: true
      }

      {:ok, error_result}
  end

  defp build_tool_call(name, arguments) do
    %{
      "id" => generate_call_id(),
      "name" => name,
      "arguments" => arguments
    }
  end

  defp generate_call_id do
    "call_#{System.system_time(:millisecond)}_#{:erlang.unique_integer([:positive])}"
  end

  defp execute_tool_call(tool, tool_call, _adapter) do
    # Create a simple signal handler for cancellation
    signal = make_ref()

    # Create an update callback
    on_update = fn _update -> :ok end

    # Execute the tool's execute function
    result = tool.execute.(tool_call["id"], tool_call["arguments"], signal, on_update)

    # Convert result to MCP ToolCallResult
    convert_result_to_mcp(result)
  end

  defp convert_result_to_mcp(result) when is_binary(result) do
    %Protocol.ToolCallResult{
      content: [
        %{
          type: "text",
          text: result
        }
      ],
      isError: false
    }
  end

  defp convert_result_to_mcp(result) when is_map(result) do
    # Handle different result formats from CodingAgent tools
    text = result["output"] || result[:output] || result["result"] || result[:result]

    error =
      result["error"] || result[:error] || result["failure"] || result[:failure]

    content =
      cond do
        is_binary(text) ->
          [%{type: "text", text: text}]

        is_binary(error) ->
          [%{type: "text", text: error}]

        true ->
          [%{type: "text", text: Jason.encode!(result)}]
      end

    %Protocol.ToolCallResult{
      content: content,
      isError: not is_nil(error)
    }
  end

  defp convert_result_to_mcp(result) do
    %Protocol.ToolCallResult{
      content: [
        %{
          type: "text",
          text: inspect(result)
        }
      ],
      isError: false
    }
  end
end
