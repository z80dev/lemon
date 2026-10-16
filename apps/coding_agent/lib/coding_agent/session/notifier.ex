defmodule CodingAgent.Session.Notifier do
  @moduledoc false

  @spec subscribe_stream(map(), pid(), keyword()) :: {:ok, pid(), map()}
  def subscribe_stream(state, pid, opts) do
    max_queue = Keyword.get(opts, :max_queue, 1000)
    drop_strategy = :resync
    timeout = Keyword.get(opts, :timeout, :infinity)

    {:ok, stream} =
      LemonAgent.EventStream.start_link(
        max_queue: max_queue,
        drop_strategy: drop_strategy,
        owner: pid,
        overflow_event:
          {:session_event, state.session_manager.header.id,
           {:stream_resync, %{reason: :overflow}}},
        timeout: timeout
      )

    mon_ref = Process.monitor(pid)

    delivery =
      LemonCore.Bus.Delivery.new(stream,
        max_queue: max_queue,
        max_bytes: Keyword.get(opts, :max_bytes, 1_048_576),
        overflow_message: {:"$gen_cast", :transport_overflow}
      )

    event_streams =
      Map.put(state.event_streams, mon_ref, %{pid: pid, stream: stream, delivery: delivery})

    {:ok, stream, %{state | event_streams: event_streams}}
  end

  @spec subscribe_direct(map(), pid(), pid(), keyword()) ::
          {(-> :ok) | {(-> :ok), LemonCore.Bus.Delivery.t()}, map()}
  def subscribe_direct(state, pid, session_pid, opts \\ []) do
    state = unsubscribe_direct(state, pid)
    monitor_ref = Process.monitor(pid)

    delivery =
      LemonCore.Bus.Delivery.new(pid,
        max_queue: Keyword.get(opts, :max_queue, 256),
        max_bytes: Keyword.get(opts, :max_bytes, 1_048_576),
        tagged: Keyword.get(opts, :tagged, false),
        overflow_message:
          {:session_event, state.session_manager.header.id,
           {:stream_resync, %{reason: :overflow}}}
      )

    new_listeners = [{pid, monitor_ref, delivery} | state.event_listeners]

    unsubscribe = fn ->
      GenServer.cast(session_pid, {:unsubscribe, pid, monitor_ref})
    end

    subscription = if delivery.tagged, do: {unsubscribe, delivery}, else: unsubscribe
    {subscription, %{state | event_listeners: new_listeners}}
  end

  @spec unsubscribe_direct(map(), pid(), reference() | nil) :: map()
  def unsubscribe_direct(state, pid, ref \\ nil) do
    new_listeners =
      Enum.reject(state.event_listeners, fn {listener_pid, monitor_ref, delivery} ->
        if listener_pid == pid and (is_nil(ref) or monitor_ref == ref) do
          LemonCore.Bus.Delivery.close(delivery)
          Process.demonitor(monitor_ref, [:flush])
          true
        else
          false
        end
      end)

    %{state | event_listeners: new_listeners}
  end

  @spec broadcast_event(map(), LemonAgent.Types.agent_event()) :: :ok
  def broadcast_event(state, event) do
    session_event = {:session_event, state.session_manager.header.id, event}

    Enum.each(state.event_listeners, fn {_pid, _ref, delivery} ->
      LemonCore.Bus.Delivery.send(delivery, session_event)
    end)

    Enum.each(state.event_streams, fn {_mon_ref, %{delivery: delivery}} ->
      LemonCore.Bus.Delivery.send(delivery, {:"$gen_cast", {:push, session_event}})
    end)

    :ok
  end

  @spec complete_event_streams(map(), term()) :: :ok
  def complete_event_streams(state, final_event) do
    final_event = Map.get(state, :terminal_event) || final_event
    # A fenced observer still receives one compact terminal indication. The
    # canonical answer stays in the owner, never in a second unbounded queue.
    status =
      case final_event do
        {:agent_end, messages} ->
          case Enum.find(Enum.reverse(messages), &match?(%{role: :assistant}, &1)) do
            %{stop_reason: :aborted} -> :canceled
            %{stop_reason: reason} when reason in [:error, :length] -> :error
            _ -> :completed
          end

        {:error, _, _} ->
          :error

        _ ->
          :canceled
      end

    Enum.each(state.event_listeners, fn {_pid, _ref, delivery} ->
      if LemonCore.Bus.Delivery.closed?(delivery) do
        LemonCore.Bus.Delivery.terminal(
          delivery,
          {:session_terminal, state.session_manager.header.id, status}
        )
      end
    end)

    Enum.each(state.event_streams, fn {mon_ref, %{delivery: delivery}} ->
      terminal =
        case final_event do
          {:agent_end, messages} when is_list(messages) ->
            {:complete, messages}

          {:error, reason, partial_state} ->
            {:error, reason, partial_state}

          {:canceled, reason} ->
            LemonCore.Bus.Delivery.send(delivery, {:"$gen_cast", {:push, {:canceled, reason}}})
            {:complete, []}

          {:turn_end, %LemonAi.Types.AssistantMessage{stop_reason: :aborted}, _tool_results} ->
            LemonCore.Bus.Delivery.send(
              delivery,
              {:"$gen_cast", {:push, {:canceled, :assistant_aborted}}}
            )

            {:complete, []}

          _ ->
            {:complete, []}
        end

      LemonCore.Bus.Delivery.send(delivery, {:"$gen_cast", terminal})
      LemonCore.Bus.Delivery.close(delivery)

      Process.demonitor(mon_ref, [:flush])
    end)

    :ok
  end

  @spec prune_subscribers(map(), pid(), reference()) :: map()
  def prune_subscribers(state, pid, ref) do
    new_listeners =
      Enum.reject(state.event_listeners, fn {listener_pid, monitor_ref, delivery} ->
        if listener_pid == pid or monitor_ref == ref, do: LemonCore.Bus.Delivery.close(delivery)
        listener_pid == pid or monitor_ref == ref
      end)

    {streams_for_pid, remaining_streams} =
      Enum.split_with(state.event_streams, fn {_mon_ref, %{pid: stream_pid}} ->
        stream_pid == pid
      end)

    Enum.each(streams_for_pid, fn {mon_ref, %{stream: stream, delivery: delivery}} ->
      LemonCore.Bus.Delivery.close(delivery)
      LemonAgent.EventStream.cancel(stream, :subscriber_down)
      Process.demonitor(mon_ref, [:flush])
    end)

    %{state | event_listeners: new_listeners, event_streams: Map.new(remaining_streams)}
  end
end
