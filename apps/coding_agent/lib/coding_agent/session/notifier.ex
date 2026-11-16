defmodule CodingAgent.Session.Notifier do
  @moduledoc false

  alias CodingAgent.Session.EventLog
  alias LemonCore.Bus.Delivery

  # Owned by the session process, like EventLog. A pending batch uses the
  # subscriber's existing count/byte budgets and retains reversed chunks only.
  @pending {__MODULE__, :pending}
  @scheduled {__MODULE__, :scheduled}

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
           {:stream_resync, %{reason: :overflow}}, nil},
        timeout: timeout,
        # This is a session subscription, not a provider response. Quiet sessions
        # and tools may outlive the provider inactivity window.
        idle_timeout: :infinity
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
           {:stream_resync, %{reason: :overflow}}, nil}
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
          discard_pending(delivery)
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
    entry = EventLog.append(state.event_log, event, state.run_id)
    session_event = {:session_event, state.session_manager.header.id, event, entry.cursor}

    LemonCore.Bus.broadcast(
      "session_events",
      LemonCore.Event.new(:session_event, Map.take(entry, [:cursor, :event_id, :events]), %{
        session_key: state.session_key,
        run_id: state.run_id,
        schema_version: 1,
        event_id: entry.event_id,
        session_seq: entry.cursor["seq"],
        cursor: entry.cursor
      })
    )

    Enum.each(state.event_listeners, fn {_pid, _ref, delivery} ->
      deliver(delivery, session_event, :direct)
    end)

    Enum.each(state.event_streams, fn {_mon_ref, %{delivery: delivery}} ->
      deliver(delivery, session_event, :stream)
    end)

    :ok
  end

  @doc false
  def flush_pending do
    Process.delete(@scheduled)

    Enum.each(Process.delete(@pending) || %{}, fn {_gate, batch} ->
      send_batch(batch)
    end)

    :ok
  end

  defp deliver(
         delivery,
         {:session_event, session_id, {:message_update, {:text_delta, index, text}}, cursor} =
           event,
         mode
       )
       when is_binary(text) do
    key = {session_id, index, mode}
    pending = Process.get(@pending, %{})
    batch = Map.get(pending, delivery.gate)
    empty = {:session_event, session_id, {:message_update, {:text_delta, index, ""}}, cursor}
    envelope = wrap(empty, mode)

    envelope =
      if delivery.tagged, do: {:lemon_bus_delivery, delivery.gate, envelope}, else: envelope

    capacity = delivery.max_bytes - :erlang.external_size(envelope)

    cond do
      Delivery.closed?(delivery) ->
        discard_pending(delivery)

      byte_size(text) > capacity ->
        flush_delivery(delivery)
        Delivery.send(delivery, wrap(event, mode))

      batch &&
          (batch.key != key or batch.bytes + byte_size(text) > capacity or
             batch.count >= delivery.max_queue) ->
        flush_delivery(delivery)
        deliver(delivery, event, mode)

      true ->
        text =
          if :binary.referenced_byte_size(text) > byte_size(text),
            do: :binary.copy(text),
            else: text

        batch = batch || %{key: key, delivery: delivery, chunks: [], bytes: 0, count: 0}

        batch = %{
          batch
          | chunks: [text | batch.chunks],
            bytes: batch.bytes + byte_size(text),
            count: batch.count + 1
        }

        batch = Map.put(batch, :cursor, cursor)
        Process.put(@pending, Map.put(pending, delivery.gate, batch))

        unless Process.get(@scheduled, false) do
          Process.put(@scheduled, true)
          send(self(), {__MODULE__, :flush})
        end
    end

    :ok
  end

  defp deliver(delivery, event, mode) do
    flush_delivery(delivery)
    Delivery.send(delivery, wrap(event, mode))
  end

  defp flush_delivery(delivery) do
    {batch, pending} = Map.pop(Process.get(@pending, %{}), delivery.gate)
    Process.put(@pending, pending)
    if batch, do: send_batch(batch)
    :ok
  end

  defp discard_pending(delivery) do
    Process.put(@pending, Map.delete(Process.get(@pending, %{}), delivery.gate))
    :ok
  end

  defp send_batch(%{key: {session_id, index, mode}} = batch) do
    text = batch.chunks |> Enum.reverse() |> IO.iodata_to_binary()

    event =
      {:session_event, session_id, {:message_update, {:text_delta, index, text}}, batch.cursor}

    Delivery.send(batch.delivery, wrap(event, mode))
  end

  defp wrap(event, :direct), do: event
  defp wrap(event, :stream), do: {:"$gen_cast", {:push, event}}

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
      flush_delivery(delivery)

      if LemonCore.Bus.Delivery.closed?(delivery) do
        LemonCore.Bus.Delivery.terminal(
          delivery,
          {:session_terminal, state.session_manager.header.id, status}
        )
      end
    end)

    Enum.each(state.event_streams, fn {mon_ref, %{delivery: delivery}} ->
      flush_delivery(delivery)

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
        if listener_pid == pid or monitor_ref == ref do
          discard_pending(delivery)
          LemonCore.Bus.Delivery.close(delivery)
        end

        listener_pid == pid or monitor_ref == ref
      end)

    {streams_for_pid, remaining_streams} =
      Enum.split_with(state.event_streams, fn {_mon_ref, %{pid: stream_pid}} ->
        stream_pid == pid
      end)

    Enum.each(streams_for_pid, fn {mon_ref, %{stream: stream, delivery: delivery}} ->
      discard_pending(delivery)
      LemonCore.Bus.Delivery.close(delivery)
      LemonAgent.EventStream.cancel(stream, :subscriber_down)
      Process.demonitor(mon_ref, [:flush])
    end)

    %{state | event_listeners: new_listeners, event_streams: Map.new(remaining_streams)}
  end
end
