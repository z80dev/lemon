defmodule CodingAgent.Tools.Todo do
  @moduledoc """
  Unified todo tool for reading and writing session todo lists.

  This replaces separate read/write todo tools with a single action-based API.
  """

  alias AgentCore.Types.AgentTool
  alias CodingAgent.Tools.{TodoRead, TodoWrite}

  @valid_actions ["read", "write"]

  @doc """
  Returns the unified todo tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "")

    %AgentTool{
      name: "todo",
      description: "Read or update the session todo list.",
      label: "Manage Todos",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @valid_actions,
            "description" => "Todo operation to run: 'read' or 'write'."
          },
          "todos" => %{
            "type" => "array",
            "description" => "Updated todo list (required when action is 'write').",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "content" => %{
                  "type" => "string",
                  "description" => "Brief description of the task"
                },
                "status" => %{
                  "type" => "string",
                  "description" => "Task status: pending, in_progress, completed"
                },
                "priority" => %{
                  "type" => "string",
                  "description" => "Priority level: high, medium, low"
                },
                "id" => %{"type" => "string", "description" => "Unique todo id"}
              },
              "required" => ["content", "status", "priority", "id"]
            }
          }
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, session_id)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentCore.Types.AgentToolResult.t() -> :ok) | nil,
          session_id :: String.t()
        ) :: AgentCore.Types.AgentToolResult.t() | {:error, term()}
  def execute(tool_call_id, params, signal, on_update, session_id) do
    case Map.get(params, "action") do
      "read" ->
        TodoRead.execute(tool_call_id, %{}, signal, on_update, session_id)

      "write" ->
        TodoWrite.execute(tool_call_id, params, signal, on_update, session_id)

      nil ->
        {:error, "action is required and must be one of: read, write"}

      _ ->
        {:error, "action must be one of: read, write"}
    end
  end
end
