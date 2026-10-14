defmodule CodingAgent.Tools.Todo do
  @moduledoc """
  Session-scoped plan management with read, write, progress and actionable views.

  `write` replaces the full list. Entries require only `content`, default to
  pending/medium, and may omit IDs; IDs remain stable across same-content updates.
  Read the returned IDs before renaming tasks. `read`, `progress`, and `actionable`
  are getters, not updates: passing `todos` to them is rejected with guidance
  to use `write`. Explicit invalid statuses, priorities and duplicate IDs reject
  a write without changing the stored plan.

  Every successful operation includes the complete normalized state in
  `details.todos` and `details.plan.entries`, even when text content is a progress
  summary or actionable subset. Plan entries are ordered maps with `content`,
  `status` (pending/in_progress/completed) and `priority` (high/medium/low), all
  string values. Actionable results additionally expose `details.actionable`.
  State is the owning session's selected-branch journal (`CodingAgent.Session.Todos`),
  so every view agrees with rewind, branch navigation, resume and forks.
  """

  alias LemonAgent.Types.AgentTool
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias CodingAgent.Tools.{TodoRead, TodoWrite}
  alias CodingAgent.Tools.TodoStore

  @valid_actions ["read", "write", "progress", "actionable"]

  @doc """
  Returns the unified todo tool definition bound to the `:session_pid` option.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, opts \\ []) do
    session = Keyword.get(opts, :session_pid)

    %AgentTool{
      name: "todo",
      description:
        "Manage the session plan. ONLY action='write' changes tasks or statuses: pass the complete todos list. " <>
          "read, progress, and actionable are read-only getters; omit todos or pass null with them. " <>
          "Write entries need content; omit IDs or pass null for generated IDs, status defaults pending, priority defaults medium. " <>
          "To mark tasks done, use write with status='completed', then progress to inspect counts.",
      label: "Manage Todos",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => @valid_actions,
            "description" =>
              "'write' replaces/updates the complete plan; 'read' reads it; 'progress' gets counts without changing anything; 'actionable' gets ready tasks. Send todos ONLY with write."
          },
          "todos" => Map.put(TodoWrite.todos_schema(), "type", ["array", "null"])
        },
        "required" => ["action"]
      },
      execute: &execute(&1, &2, &3, &4, session)
    }
  end

  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (LemonAgent.Types.AgentToolResult.t() -> :ok) | nil,
          session :: GenServer.server() | nil
        ) :: LemonAgent.Types.AgentToolResult.t() | {:error, term()}
  def execute(
        _tool_call_id,
        %{"action" => action, "todos" => todos},
        _signal,
        _on_update,
        _session
      )
      when action in ["read", "progress", "actionable"] and not is_nil(todos) do
    {:error,
     "action='#{action}' is read-only and cannot update todos. Use action='write' with the complete updated list to change statuses; no plan state was changed."}
  end

  def execute(tool_call_id, params, signal, on_update, session) do
    case Map.get(params, "action") do
      "read" ->
        TodoRead.execute(tool_call_id, %{}, signal, on_update, session)

      "write" ->
        TodoWrite.execute(tool_call_id, params, signal, on_update, session)

      "progress" ->
        execute_progress(signal, session)

      "actionable" ->
        execute_actionable(signal, session)

      nil ->
        {:error, "action is required and must be one of: read, write, progress, actionable"}

      _ ->
        {:error, "action must be one of: read, write, progress, actionable"}
    end
  end

  defp execute_progress(signal, session) do
    if LemonAgent.AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with {:ok, todos} <- TodoRead.readable(session) do
        progress = TodoStore.progress(todos)
        output = Jason.encode!(progress, pretty: true)

        %AgentToolResult{
          content: [%TextContent{text: output}],
          details:
            todos
            |> TodoStore.result_details()
            |> Map.merge(progress)
            |> Map.put(:title, "todo progress")
        }
      end
    end
  end

  defp execute_actionable(signal, session) do
    if LemonAgent.AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with {:ok, todos} <- TodoRead.readable(session) do
        actionable = TodoStore.actionable(todos)
        output = Jason.encode!(actionable, pretty: true)

        %AgentToolResult{
          content: [%TextContent{text: output}],
          details:
            todos
            |> TodoStore.result_details()
            |> Map.put(:title, "#{length(actionable)} actionable todos")
            |> Map.put(:actionable, TodoStore.result_details(actionable).todos)
        }
      end
    end
  end
end
