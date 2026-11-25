defmodule CodingAgent.Progress do
  @moduledoc """
  Aggregates long-running harness progress for a coding-agent session.

  Combines journal-derived todos with checkpoint statistics and returns a
  normalized snapshot suitable for control-plane/reporting surfaces.
  """

  alias CodingAgent.Checkpoint
  alias CodingAgent.Tools.Todo

  @type snapshot :: %{
          todos: map() | nil,
          checkpoints: map(),
          overall_percentage: non_neg_integer(),
          next_actions: %{todos: [map()]}
        }

  @spec snapshot(String.t(), String.t()) :: snapshot()
  def snapshot(session_id, cwd \\ ".") when is_binary(session_id) and is_binary(cwd) do
    {todo_progress, todo_next} =
      case CodingAgent.ControlPlaneProvider.native_session_todos(session_id, cwd) do
        {:ok, todos, _revision} -> {Todo.progress(todos), Todo.actionable(todos)}
        {:error, _} -> {nil, []}
      end

    %{
      todos: todo_progress,
      checkpoints: Checkpoint.stats(session_id),
      overall_percentage: if(todo_progress, do: todo_progress.percentage, else: 0),
      next_actions: %{todos: Enum.map(todo_next, &format_todo/1)}
    }
  end

  defp format_todo(todo) do
    %{
      id: todo["id"] || todo[:id],
      content: todo["content"] || todo[:content],
      status: todo["status"] || todo[:status],
      priority: todo["priority"] || todo[:priority],
      dependencies: todo["dependencies"] || todo[:dependencies] || []
    }
  end
end
