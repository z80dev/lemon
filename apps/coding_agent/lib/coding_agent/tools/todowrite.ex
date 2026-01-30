defmodule CodingAgent.Tools.TodoWrite do
  @moduledoc """
  Todo write tool for the coding agent.

  Stores a todo list for the current session.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.TodoStore

  @doc """
  Returns the TodoWrite tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "")

    %AgentTool{
      name: "todowrite",
      description: "Write the session todo list.",
      label: "Write Todos",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "todos" => %{
            "type" => "array",
            "description" => "Updated todo list",
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
        "required" => ["todos"]
      },
      execute: &execute(&1, &2, &3, &4, session_id)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          session_id :: String.t()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, session_id) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      todos = Map.get(params, "todos")

      cond do
        not is_list(todos) ->
          {:error, "Todos must be an array"}

        session_id == "" ->
          {:error, "Session id not available"}

        true ->
          TodoStore.put(session_id, todos)

          output = Jason.encode!(todos, pretty: true)
          open_count = Enum.count(todos, fn todo -> todo["status"] != "completed" end)

          %AgentToolResult{
            content: [%TextContent{text: output}],
            details: %{title: "#{open_count} todos", todos: todos}
          }
      end
    end
  end
end
