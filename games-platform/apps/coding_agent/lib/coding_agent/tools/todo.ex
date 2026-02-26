defmodule CodingAgent.Tools.Todo do
  @moduledoc """
  Unified todo tool for reading and writing session todo lists.

  This replaces separate read/write todo tools with a single action-based API.
  """

  alias AgentCore.Types.AgentTool
  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.{TodoRead, TodoWrite}
  alias CodingAgent.Tools.TodoStore

  @valid_actions ["read", "write", "progress", "actionable"]

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
            "description" =>
              "Todo operation to run: 'read', 'write', 'progress', or 'actionable'."
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

      "progress" ->
        execute_progress(signal, session_id)

      "actionable" ->
        execute_actionable(signal, session_id)

      nil ->
        {:error, "action is required and must be one of: read, write, progress, actionable"}

      _ ->
        {:error, "action must be one of: read, write, progress, actionable"}
    end
  end

  defp execute_progress(signal, session_id) do
    if AgentCore.AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      if session_id == "" do
        {:error, "Session id not available"}
      else
        progress = TodoStore.get_progress(session_id)
        output = Jason.encode!(progress, pretty: true)

        %AgentToolResult{
          content: [%TextContent{text: output}],
          details: Map.put(progress, :title, "todo progress")
        }
      end
    end
  end

  defp execute_actionable(signal, session_id) do
    if AgentCore.AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      if session_id == "" do
        {:error, "Session id not available"}
      else
        actionable = TodoStore.get_actionable(session_id)
        output = Jason.encode!(actionable, pretty: true)

        %AgentToolResult{
          content: [%TextContent{text: output}],
          details: %{title: "#{length(actionable)} actionable todos", todos: actionable}
        }
      end
    end
  end
end
