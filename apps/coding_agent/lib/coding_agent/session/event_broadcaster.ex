defmodule CodingAgent.Session.EventBroadcaster do
  @moduledoc """
  Manages event broadcasting to session subscribers.

  Handles broadcasting events to both direct subscribers (via send/2) and
  stream subscribers (via EventStream with backpressure), as well as completing
  event streams with terminal lifecycle events.
  """

  # ============================================================================
  # Event Broadcasting
  # ============================================================================

  @doc """
  Broadcast an event to all session subscribers (both direct and stream).

  Direct subscribers receive `{:session_event, session_id, event}` via `send/2`.
  Stream subscribers receive the same tuple via `EventStream.push_async/2`.
  """
  @spec broadcast(map(), AgentCore.Types.agent_event()) :: :ok
  def broadcast(state, event) do
    session_event = {:session_event, state.session_manager.header.id, event}

    # Direct subscribers (legacy)
    Enum.each(state.event_listeners, fn {pid, _ref} ->
      send(pid, session_event)
    end)

    # Stream subscribers (with backpressure)
    Enum.each(state.event_streams, fn {_mon_ref, %{stream: stream}} ->
      AgentCore.EventStream.push_async(stream, session_event)
    end)

    :ok
  end

  # ============================================================================
  # Stream Completion
  # ============================================================================

  @doc """
  Complete all event streams with a terminal lifecycle event.

  Different terminal events produce different completion semantics:
  - `{:agent_end, messages}` -> `complete(stream, messages)`
  - `{:error, reason, partial_state}` -> `error(stream, reason, partial_state)`
  - `{:canceled, reason}` -> push canceled event then complete
  - `{:turn_end, aborted_msg, _}` -> push canceled event then complete
  - Other -> `complete(stream, [])`

  After completion, monitors for stream subscriber processes are cleaned up.
  """
  @spec complete_streams(map(), term()) :: :ok
  def complete_streams(state, final_event) do
    Enum.each(state.event_streams, fn {mon_ref, %{stream: stream}} ->
      case final_event do
        {:agent_end, messages} when is_list(messages) ->
          AgentCore.EventStream.complete(stream, messages)

        {:error, reason, partial_state} ->
          AgentCore.EventStream.error(stream, reason, partial_state)

        {:canceled, reason} ->
          AgentCore.EventStream.push_async(stream, {:canceled, reason})
          AgentCore.EventStream.complete(stream, [])

        {:turn_end, %Ai.Types.AssistantMessage{stop_reason: :aborted}, _tool_results} ->
          AgentCore.EventStream.push_async(stream, {:canceled, :assistant_aborted})
          AgentCore.EventStream.complete(stream, [])

        _ ->
          AgentCore.EventStream.complete(stream, [])
      end

      Process.demonitor(mon_ref, [:flush])
    end)

    :ok
  end
end
