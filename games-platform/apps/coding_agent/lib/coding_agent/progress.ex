defmodule CodingAgent.Progress do
  @moduledoc """
  Aggregates long-running harness progress for a coding-agent session.

  Combines TodoStore progress with optional feature requirements progress
  and returns a normalized snapshot suitable for control-plane/reporting
  surfaces.
  """

  alias CodingAgent.Checkpoint
  alias CodingAgent.Tools.{FeatureRequirements, TodoStore}

  @type snapshot :: %{
          todos: map(),
          features: map() | nil,
          checkpoints: map(),
          overall_percentage: non_neg_integer(),
          next_actions: %{todos: [map()], features: [map()]}
        }

  @spec snapshot(String.t(), String.t()) :: snapshot()
  def snapshot(session_id, cwd \\ ".") when is_binary(session_id) and is_binary(cwd) do
    todo_progress = TodoStore.get_progress(session_id)
    todo_next = TodoStore.get_actionable(session_id)

    feature_progress =
      case FeatureRequirements.get_progress(cwd) do
        {:ok, progress} -> progress
        {:error, _} -> nil
      end

    feature_next =
      case FeatureRequirements.get_next_features(cwd) do
        {:ok, features} -> features
        {:error, _} -> []
      end

    %{
      todos: todo_progress,
      features: feature_progress,
      checkpoints: Checkpoint.stats(session_id),
      overall_percentage: overall_percentage(todo_progress, feature_progress),
      next_actions: %{
        todos: Enum.map(todo_next, &format_todo/1),
        features: Enum.map(feature_next, &format_feature/1)
      }
    }
  end

  defp overall_percentage(todo_progress, nil), do: todo_progress[:percentage] || 0

  defp overall_percentage(todo_progress, feature_progress) do
    todo_total = todo_progress[:total] || 0
    feature_total = feature_progress[:total] || 0

    combined_total = todo_total + feature_total

    if combined_total == 0 do
      0
    else
      todo_completed = todo_progress[:completed] || 0
      feature_completed = feature_progress[:completed] || 0
      div((todo_completed + feature_completed) * 100, combined_total)
    end
  end

  defp format_todo(todo) do
    %{
      id: todo.id,
      content: todo.content,
      status: todo.status,
      priority: todo.priority,
      dependencies: todo.dependencies
    }
  end

  defp format_feature(feature) do
    %{
      id: feature.id,
      description: feature.description,
      status: feature.status,
      priority: feature.priority,
      dependencies: feature.dependencies
    }
  end
end
