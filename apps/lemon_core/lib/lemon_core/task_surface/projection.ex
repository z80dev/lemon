defmodule LemonCore.TaskSurface.Projection do
  @moduledoc """
  Shared projection logic for mapping child-run progress into parent task surfaces.
  """

  @doc """
  Project a child-run engine_action payload into a parent-owned task surface payload.
  """
  def project_child_payload(payload, binding) when is_map(payload) and is_map(binding) do
    action = Map.get(payload, :action) || %{}
    detail = Map.get(action, :detail) || %{}
    child_action_id = Map.get(action, :id)
    kind = Map.get(action, :kind)
    title = Map.get(action, :title)

    %{
      engine: Map.get(payload, :engine),
      phase: Map.get(payload, :phase),
      ok: Map.get(payload, :ok),
      message: Map.get(payload, :message),
      level: Map.get(payload, :level),
      action: %{
        id: projected_action_id(binding.child_run_id, child_action_id, kind, title),
        kind: kind,
        title: title,
        detail:
          detail
          |> Map.put(:parent_tool_use_id, binding.root_action_id)
          |> Map.put(:task_id, binding.task_id)
          |> Map.put(:child_run_id, binding.child_run_id)
          |> Map.put(:projected_from, :child_run)
      }
    }
  end

  @doc false
  def projected_action_id(child_run_id, child_action_id, _kind, _title)
      when is_binary(child_action_id) and child_action_id != "" do
    "taskproj:" <> child_run_id <> ":" <> child_action_id
  end

  def projected_action_id(child_run_id, kind, title_kind, title) do
    normalized_kind = kind |> to_string()
    normalized_title = (title || title_kind || "") |> to_string()

    short_hash =
      :crypto.hash(:sha256, normalized_title) |> Base.encode16(case: :lower) |> binary_part(0, 12)

    "taskproj:" <> child_run_id <> ":" <> normalized_kind <> ":" <> short_hash
  end
end
