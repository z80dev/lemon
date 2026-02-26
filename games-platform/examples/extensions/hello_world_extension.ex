# Example Extension for Lemon
#
# This is a minimal example extension demonstrating the Extension behaviour.
# Extensions can provide custom tools and hooks to the coding agent.
#
# To install this extension:
#   1. Copy this file to ~/.lemon/agent/extensions/hello_world_extension.ex
#   2. Or copy to your project's .lemon/extensions/ directory
#
# The extension will be automatically discovered and loaded on session start.

defmodule HelloWorldExtension do
  @moduledoc """
  A simple example extension that provides a "hello" tool.

  This extension demonstrates:
  - Implementing the Extension behaviour
  - Providing a custom tool with parameters
  - Registering hooks for agent events
  """

  @behaviour CodingAgent.Extensions.Extension

  @impl true
  def name, do: "hello-world"

  @impl true
  def version, do: "1.0.0"

  @impl true
  def tools(_cwd) do
    [
      %AgentCore.Types.AgentTool{
        name: "hello",
        description: "Says hello to someone. Use this to greet users.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "The name of the person to greet"
            }
          },
          "required" => ["name"]
        },
        label: "Hello",
        execute: &execute_hello/4
      }
    ]
  end

  @impl true
  def hooks do
    [
      on_agent_start: fn ->
        # Called when the agent run starts
        :ok
      end,
      on_tool_execution_end: fn _id, name, _result, _is_error ->
        # Called after any tool finishes executing
        if name == "hello" do
          # You could log, send metrics, etc.
          :ok
        end
      end
    ]
  end

  # Tool implementation
  defp execute_hello(_tool_use_id, %{"name" => name}, _abort_signal, _on_update) do
    greeting = "Hello, #{name}! 👋"

    %AgentCore.Types.AgentToolResult{
      content: [%{type: "text", text: greeting}]
    }
  end
end
