defmodule CodingAgent.Session.Notifier do
  @moduledoc false

  alias CodingAgent.UI.Context, as: UIContext

  @spec ui_set_working_message(map(), String.t() | nil) :: :ok
  def ui_set_working_message(state, message) do
    case state.ui_context do
      %UIContext{} = ui -> UIContext.set_working_message(ui, message)
      _ -> :ok
    end
  end

  @spec ui_notify(map(), String.t(), CodingAgent.UI.notify_type()) :: :ok
  def ui_notify(state, message, type) do
    case state.ui_context do
      %UIContext{} = ui -> UIContext.notify(ui, message, type)
      _ -> :ok
    end
  end

  @spec maybe_register_ui_tracker(term()) :: :ok | term()
  def maybe_register_ui_tracker(%UIContext{module: mod, state: tracker})
      when not is_nil(tracker) do
    if function_exported?(mod, :register_tracker, 1) do
      mod.register_tracker(tracker)
    else
      :ok
    end
  end

  def maybe_register_ui_tracker(_), do: :ok

  @spec subscribe_stream(map(), pid(), keyword()) :: {:ok, pid(), map()}
  def subscribe_stream(state, pid, opts) do
    max_queue = Keyword.get(opts, :max_queue, 1000)
    drop_strategy = Keyword.get(opts, :drop_strategy, :drop_oldest)
    timeout = Keyword.get(opts, :timeout, :infinity)

    {:ok, stream} =
      AgentCore.EventStream.start_link(
        max_queue: max_queue,
        drop_strategy: drop_strategy,
        owner: pid,
        timeout: timeout
      )

    mon_ref = Process.monitor(pid)
    event_streams = Map.put(state.event_streams, mon_ref, %{pid: pid, stream: stream})

    {:ok, stream, %{state | event_streams: event_streams}}
  end

  @spec subscribe_direct(map(), pid(), pid()) :: {(-> :ok), map()}
  def subscribe_direct(state, pid, session_pid) do
    monitor_ref = Process.monitor(pid)
    new_listeners = [{pid, monitor_ref} | state.event_listeners]

    unsubscribe = fn ->
      GenServer.cast(session_pid, {:unsubscribe, pid})
    end

    {unsubscribe, %{state | event_listeners: new_listeners}}
  end

  @spec unsubscribe_direct(map(), pid()) :: map()
  def unsubscribe_direct(state, pid) do
    new_listeners =
      Enum.reject(state.event_listeners, fn {listener_pid, monitor_ref} ->
        if listener_pid == pid do
          Process.demonitor(monitor_ref, [:flush])
          true
        else
          false
        end
      end)

    %{state | event_listeners: new_listeners}
  end

  @spec broadcast_event(map(), AgentCore.Types.agent_event()) :: :ok
  def broadcast_event(state, event) do
    session_event = {:session_event, state.session_manager.header.id, event}

    Enum.each(state.event_listeners, fn {pid, _ref} ->
      send(pid, session_event)
    end)

    Enum.each(state.event_streams, fn {_mon_ref, %{stream: stream}} ->
      AgentCore.EventStream.push_async(stream, session_event)
    end)

    :ok
  end

  @spec complete_event_streams(map(), term()) :: :ok
  def complete_event_streams(state, final_event) do
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

  @spec prune_subscribers(map(), pid(), reference()) :: map()
  def prune_subscribers(state, pid, ref) do
    new_listeners =
      Enum.reject(state.event_listeners, fn {listener_pid, monitor_ref} ->
        listener_pid == pid or monitor_ref == ref
      end)

    {streams_for_pid, remaining_streams} =
      Enum.split_with(state.event_streams, fn {_mon_ref, %{pid: stream_pid}} ->
        stream_pid == pid
      end)

    Enum.each(streams_for_pid, fn {mon_ref, %{stream: stream}} ->
      AgentCore.EventStream.cancel(stream, :subscriber_down)
      Process.demonitor(mon_ref, [:flush])
    end)

    %{state | event_listeners: new_listeners, event_streams: Map.new(remaining_streams)}
  end
end
