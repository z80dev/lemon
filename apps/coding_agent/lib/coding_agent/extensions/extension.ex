defmodule CodingAgent.Extensions.Extension do
  @moduledoc """
  Behaviour for CodingAgent extensions.

  Extensions can provide additional tools, custom hooks, and other
  capabilities to the coding agent. Implementing this behaviour
  allows extensions to be discovered and loaded automatically.

  ## Implementing an Extension

      defmodule MyExtension do
        @behaviour CodingAgent.Extensions.Extension

        @impl true
        def name, do: "my-extension"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def tools(cwd) do
          [
            %AgentCore.Types.AgentTool{
              name: "my_tool",
              description: "Does something useful",
              parameters: %{
                "type" => "object",
                "properties" => %{
                  "input" => %{"type" => "string", "description" => "Input value"}
                },
                "required" => ["input"]
              },
              label: "My Tool",
              execute: fn _id, %{"input" => input}, _signal, _on_update ->
                %AgentCore.Types.AgentToolResult{
                  content: [%{type: "text", text: "Result: \#{input}"}]
                }
              end
            }
          ]
        end

        @impl true
        def hooks do
          [
            on_message_start: fn message -> IO.inspect(message, label: "Message started") end,
            on_tool_execution_end: fn id, name, result, _is_error ->
              IO.puts("Tool \#{name} (\#{id}) completed")
            end
          ]
        end
      end

  ## Hooks

  Extensions can register hooks for various agent events:

  - `:on_agent_start` - `fn -> :ok` - Called when agent run starts
  - `:on_agent_end` - `fn messages -> :ok` - Called when agent run ends
  - `:on_turn_start` - `fn -> :ok` - Called when a new turn starts
  - `:on_turn_end` - `fn message, tool_results -> :ok` - Called when turn ends
  - `:on_message_start` - `fn message -> :ok` - Called when message processing starts
  - `:on_message_end` - `fn message -> :ok` - Called when message processing ends
  - `:on_tool_execution_start` - `fn id, name, args -> :ok` - Called when tool starts
  - `:on_tool_execution_end` - `fn id, name, result, is_error -> :ok` - Called when tool ends
  """

  @doc """
  Returns the extension's unique name.

  This should be a lowercase string with hyphens (e.g., "my-extension").
  """
  @callback name() :: String.t()

  @doc """
  Returns the extension's version string.

  Should follow semantic versioning (e.g., "1.0.0").
  """
  @callback version() :: String.t()

  @doc """
  Returns a list of tools provided by this extension.

  The `cwd` parameter is the current working directory, allowing
  tools to be context-aware.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A list of `AgentCore.Types.AgentTool` structs.
  """
  @callback tools(cwd :: String.t()) :: [AgentCore.Types.AgentTool.t()]

  @doc """
  Returns a keyword list of hooks for agent events.

  Each hook is a function that will be called when the corresponding
  event occurs. See the module documentation for available hooks.

  ## Returns

  A keyword list where keys are hook names (atoms) and values are
  callback functions.
  """
  @callback hooks() :: keyword()

  @optional_callbacks [tools: 1, hooks: 0]
end
