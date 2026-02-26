defmodule CodingAgent.Tools.TodoRead do
  @moduledoc """
  Todo read tool for the coding agent.

  Reads the stored todo list for the current session.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.TodoStore

  @doc """
  Returns the TodoRead tool definition.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "")

    %AgentTool{
      name: "todoread",
      description: "Read the session todo list.",
      label: "Read Todos",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
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
  def execute(_tool_call_id, _params, signal, _on_update, session_id) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      if session_id == "" do
        {:error, "Session id not available"}
      else
        todos = TodoStore.get(session_id)
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
