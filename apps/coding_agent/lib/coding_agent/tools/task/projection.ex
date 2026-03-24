defmodule CodingAgent.Tools.Task.Projection do
  @moduledoc """
  Shared projection logic for mapping child-run progress into parent-owned
  engine_action payloads.

  Used by both `Async` (to emit child :engine_action events) and
  `LiveBridge` / router-side subscribers (to project child actions into
  the parent task surface).
  """

  alias AgentCore.Types.AgentToolResult

  @terminal_event_types [
    :run_completed,
    :task_completed,
    :task_error,
    :task_timeout,
    :task_aborted
  ]

  @doc "Returns true if the given event type is a terminal lifecycle event."
  def terminal_event_type?(type), do: type in @terminal_event_types

  @doc """
  Build an `:engine_action` payload from an `AgentToolResult` update
  that contains a `current_action` in its details.

  Returns `{:ok, payload}` or `:error`.
  """
  def engine_action_from_update(
        %AgentToolResult{details: details},
        lifecycle_context
      )
      when is_map(details) and is_map(lifecycle_context) do
    run_id = lifecycle_context[:run_id]

    if not is_binary(run_id) or run_id == "" do
      :error
    else
      current_action = details[:current_action] || details["current_action"]
      action_detail = details[:action_detail] || details["action_detail"] || %{}

      with %{title: title, kind: kind, phase: phase} <- normalize_current_action(current_action) do
        {:ok,
         %{
           engine: details[:engine] || details["engine"] || lifecycle_context[:engine],
           phase: normalize_phase(phase),
           ok: normalize_ok(phase),
           message: nil,
           level: nil,
           action: %{
             id: stable_child_action_id(run_id, kind, title),
             kind: normalize_kind(kind),
             title: title,
             detail: action_detail
           }
         }}
      else
        _ -> :error
      end
    end
  end

  def engine_action_from_update(_, _), do: :error

  @doc """
  Project a child-run engine_action payload into a parent-owned task surface payload.

  Used by both LiveBridge and the router-side AsyncTaskSurfaceSubscriber to produce
  identical projected action ids.
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

  # ---- Private ----

  defp normalize_current_action(%{title: title, kind: kind, phase: phase})
       when is_binary(title) and title != "" and
              is_binary(kind) and kind != "" and
              is_binary(phase) and phase != "" do
    %{title: title, kind: kind, phase: phase}
  end

  defp normalize_current_action(%{"title" => title, "kind" => kind, "phase" => phase})
       when is_binary(title) and title != "" and
              is_binary(kind) and kind != "" and
              is_binary(phase) and phase != "" do
    %{title: title, kind: kind, phase: phase}
  end

  defp normalize_current_action(_), do: nil

  defp normalize_phase("started"), do: :started
  defp normalize_phase("updated"), do: :updated
  defp normalize_phase("completed"), do: :completed
  defp normalize_phase(atom) when is_atom(atom), do: atom
  defp normalize_phase(_), do: :updated

  defp normalize_ok("completed"), do: true
  defp normalize_ok(:completed), do: true
  defp normalize_ok(_), do: nil

  defp normalize_kind(kind) when is_binary(kind), do: kind
  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(_), do: "tool"

  defp stable_child_action_id(run_id, kind, title)
       when is_binary(run_id) and is_binary(kind) and is_binary(title) do
    digest =
      "#{kind}:#{title}"
      |> :erlang.md5()
      |> Base.encode16(case: :lower)

    "childaction:#{run_id}:#{digest}"
  end

  defp stable_child_action_id(run_id, _, _), do: "childaction:#{run_id}:unknown"

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
