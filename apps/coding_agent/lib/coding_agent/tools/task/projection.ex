defmodule CodingAgent.Tools.Task.Projection do
  @moduledoc """
  CodingAgent task progress projection helpers.
  """

  alias AgentCore.Types.AgentToolResult
  alias LemonCore.Event
  alias LemonCore.TaskSurface.Projection, as: CoreProjection

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
  that contains a `current_action` or `reasoning` entry in its details.

  Returns `{:ok, payload}` or `:error`.
  """
  def engine_action_from_update(
        %AgentToolResult{details: details},
        lifecycle_context
      )
      when is_map(details) and is_map(lifecycle_context) do
    with {:ok, %Event{payload: payload}} <-
           engine_action_event_from_update(%AgentToolResult{details: details}, lifecycle_context) do
      {:ok, payload}
    end
  end

  def engine_action_from_update(_, _), do: :error

  @doc """
  Build a canonical `:engine_action` event from an `AgentToolResult` update.
  """
  def engine_action_event_from_update(
        %AgentToolResult{details: details},
        lifecycle_context
      )
      when is_map(details) and is_map(lifecycle_context) do
    run_id = lifecycle_context[:run_id]

    if not is_binary(run_id) or run_id == "" do
      :error
    else
      current_action = details[:current_action] || details["current_action"]
      reasoning = details[:reasoning] || details["reasoning"]
      action_detail = details[:action_detail] || details["action_detail"] || %{}

      case normalize_current_action(current_action) do
        %{title: title, kind: kind, phase: phase} ->
          payload = %{
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
          }

          {:ok, Event.engine_action(payload, event_meta(lifecycle_context))}

        nil ->
          case normalize_reasoning(reasoning) do
            %{text: text, source: source, phase: phase} ->
              build_reasoning_event(details, lifecycle_context, text, source, phase)

            nil ->
              :error
          end
      end
    end
  end

  def engine_action_event_from_update(_, _), do: :error

  defdelegate project_child_payload(payload, binding), to: CoreProjection

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

  defp normalize_reasoning(%{text: text} = reasoning) when is_binary(text) and text != "" do
    %{
      text: text,
      source: Map.get(reasoning, :source) || Map.get(reasoning, "source") || "unknown",
      phase: Map.get(reasoning, :phase) || Map.get(reasoning, "phase") || "updated"
    }
  end

  defp normalize_reasoning(%{"text" => text} = reasoning) when is_binary(text) and text != "" do
    %{
      text: text,
      source: Map.get(reasoning, "source") || "unknown",
      phase: Map.get(reasoning, "phase") || "updated"
    }
  end

  defp normalize_reasoning(_), do: nil

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

  defp build_reasoning_event(details, lifecycle_context, text, source, phase) do
    session_key = lifecycle_context[:session_key]
    run_id = lifecycle_context[:run_id]

    if is_binary(session_key) and session_key != "" do
      attrs =
        event_meta(lifecycle_context)
        |> Map.merge(%{
          engine: details[:engine] || details["engine"] || lifecycle_context[:engine],
          text: text,
          source: source,
          phase: phase,
          visibility: :operator,
          action_id: stable_child_action_id(run_id, "reasoning", text)
        })

      {:ok, Event.engine_reasoning(attrs)}
    else
      :error
    end
  end

  defp event_meta(lifecycle_context) do
    %{
      run_id: lifecycle_context[:run_id],
      parent_run_id: lifecycle_context[:parent_run_id],
      session_key: lifecycle_context[:session_key],
      agent_id: lifecycle_context[:agent_id],
      task_id: lifecycle_context[:task_id]
    }
  end

  defp stable_child_action_id(run_id, kind, title)
       when is_binary(run_id) and is_binary(kind) and is_binary(title) do
    digest =
      "#{kind}:#{title}"
      |> :erlang.md5()
      |> Base.encode16(case: :lower)

    "childaction:#{run_id}:#{digest}"
  end

  defp stable_child_action_id(run_id, _, _), do: "childaction:#{run_id}:unknown"

  defdelegate projected_action_id(child_run_id, child_action_id, kind, title), to: CoreProjection
end
