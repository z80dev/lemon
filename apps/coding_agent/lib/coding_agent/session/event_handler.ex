defmodule CodingAgent.Session.EventHandler do
  @moduledoc false

  alias CodingAgent.Extensions
  alias LemonCore.Introspection

  @type callbacks(state) :: %{
          required(:set_working_message) => (state, String.t() | nil -> :ok),
          required(:notify) => (state, String.t(), CodingAgent.UI.notify_type() -> :ok),
          required(:complete_event_streams) => (state, term() -> :ok),
          required(:maybe_trigger_compaction) => (state -> state),
          required(:persist_message) => (state, term() -> state)
        }

  @spec handle(AgentCore.Types.agent_event(), state, callbacks(state)) :: state when state: map()
  def handle({:agent_start}, state, _callbacks) do
    # Execute on_agent_start hooks
    Extensions.execute_hooks(state.hooks, :on_agent_start, [])
    state
  end

  def handle({:turn_start}, state, _callbacks) do
    # Execute on_turn_start hooks
    Extensions.execute_hooks(state.hooks, :on_turn_start, [])
    state
  end

  def handle({:turn_end, message, tool_results}, state, callbacks) do
    # Execute on_turn_end hooks
    Extensions.execute_hooks(state.hooks, :on_turn_end, [message, tool_results])

    # Abort can terminate the underlying stream before {:canceled, reason} is observed.
    # Treat an aborted assistant turn as terminal to keep Session lifecycle consistent.
    case message do
      %Ai.Types.AssistantMessage{stop_reason: :aborted} ->
        callbacks.set_working_message.(state, nil)
        callbacks.complete_event_streams.(state, {:turn_end, message, tool_results})
        %{state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}

      _ ->
        state
    end
  end

  def handle({:message_start, message}, state, _callbacks) do
    # Execute on_message_start hooks
    Extensions.execute_hooks(state.hooks, :on_message_start, [message])
    state
  end

  def handle({:message_end, message}, state, callbacks) do
    # Execute on_message_end hooks
    Extensions.execute_hooks(state.hooks, :on_message_end, [message])

    new_state = callbacks.persist_message.(state, message)

    # Some abort paths can terminate after :message_end without emitting
    # :turn_end/:agent_end/:canceled. Treat aborted assistant messages as terminal
    # to avoid leaving the session in a permanently streaming state.
    case message do
      %Ai.Types.AssistantMessage{stop_reason: :aborted} ->
        callbacks.set_working_message.(new_state, nil)
        callbacks.complete_event_streams.(new_state, {:canceled, :assistant_aborted})
        %{new_state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}

      _ ->
        new_state
    end
  end

  def handle({:tool_execution_start, id, name, args}, state, callbacks) do
    # Execute on_tool_execution_start hooks
    Extensions.execute_hooks(state.hooks, :on_tool_execution_start, [id, name, args])

    # Emit introspection event for tool call dispatch
    Introspection.record(:tool_call_dispatched, %{
      tool_name: name,
      tool_call_id: id
    }, engine: "lemon", provenance: :direct)

    callbacks.set_working_message.(state, "Running #{name}...")
    state
  end

  def handle({:tool_execution_end, id, name, result, is_error}, state, callbacks) do
    # Execute on_tool_execution_end hooks
    Extensions.execute_hooks(state.hooks, :on_tool_execution_end, [id, name, result, is_error])

    callbacks.set_working_message.(state, nil)
    state
  end

  def handle({:agent_end, messages}, state, callbacks) do
    # Execute on_agent_end hooks
    Extensions.execute_hooks(state.hooks, :on_agent_end, [messages])

    # Clear working message and steering queue
    callbacks.set_working_message.(state, nil)

    # Complete all event streams with the final event
    callbacks.complete_event_streams.(state, {:agent_end, messages})

    # Check if compaction is needed
    new_state = %{state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}
    callbacks.maybe_trigger_compaction.(new_state)
  end

  def handle({:error, reason, partial_state}, state, callbacks) do
    callbacks.set_working_message.(state, nil)
    callbacks.notify.(state, "Agent error: #{inspect(reason)}", :error)

    # Complete all event streams with the error event
    callbacks.complete_event_streams.(state, {:error, reason, partial_state})

    %{state | is_streaming: false, event_streams: %{}}
  end

  def handle({:canceled, reason}, state, callbacks) do
    # Canceled is a terminal lifecycle event (e.g. abort) and may occur without :agent_end.
    callbacks.set_working_message.(state, nil)

    # Complete all event streams with the canceled event
    callbacks.complete_event_streams.(state, {:canceled, reason})

    %{state | is_streaming: false, steering_queue: :queue.new(), event_streams: %{}}
  end

  def handle(_event, state, _callbacks) do
    state
  end
end
