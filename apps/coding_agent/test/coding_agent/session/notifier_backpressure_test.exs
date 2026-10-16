defmodule CodingAgent.Session.NotifierBackpressureTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.Notifier
  alias LemonAgent.EventStream

  test "noisy tool progress fences a slow direct subscriber but reserves terminal truth once" do
    consumer = frozen_consumer()
    {_unsubscribe, state} = Notifier.subscribe_direct(state(), consumer, self(), max_queue: 8)

    for n <- 1..2000 do
      assert :ok =
               Notifier.broadcast_event(
                 state,
                 {:tool_execution_update, "tool-1", "bash", %{}, %{output: "line #{n}"}}
               )
    end

    assert {:message_queue_len, 9} = Process.info(consumer, :message_queue_len)
    assert :ok = Notifier.broadcast_event(state, {:agent_end, [:canonical_answer]})
    assert :ok = Notifier.complete_event_streams(state, {:agent_end, [:canonical_answer]})
    assert :ok = Notifier.complete_event_streams(state, {:canceled, :late_cancel})
    assert :ok = Notifier.broadcast_event(state, {:agent_start})
    assert {:message_queue_len, 10} = Process.info(consumer, :message_queue_len)

    messages = drain(consumer)

    assert Enum.count(
             messages,
             &match?({:session_event, "session-1", {:tool_execution_update, _, _, _, _}}, &1)
           ) == 8

    assert Enum.count(
             messages,
             &(&1 == {:session_event, "session-1", {:stream_resync, %{reason: :overflow}}})
           ) == 1

    assert List.last(messages) == {:session_terminal, "session-1", :completed}
    refute Enum.any?(messages, &(&1 == {:session_terminal, "session-1", :canceled}))
  end

  test "cancel and failure terminal truth use the same compact bounded recovery path" do
    for {event, expected} <- [
          {{:canceled, :assistant_aborted}, :canceled},
          {{:error, :provider_failed, nil}, :error},
          {{:agent_end, [%LemonAi.Types.AssistantMessage{stop_reason: :error}]}, :error},
          {{:agent_end, [%LemonAi.Types.AssistantMessage{stop_reason: :length}]}, :error},
          {{:agent_end, [%LemonAi.Types.AssistantMessage{stop_reason: :aborted}]}, :canceled}
        ] do
      consumer = frozen_consumer()
      {_unsubscribe, state} = Notifier.subscribe_direct(state(), consumer, self(), max_queue: 1)
      Notifier.broadcast_event(state, {:agent_start})
      Notifier.broadcast_event(state, {:tool_execution_start, "id", "bash", %{}})
      Notifier.complete_event_streams(state, event)
      assert List.last(drain(consumer)) == {:session_terminal, "session-1", expected}
    end
  end

  test "stream ingress is bounded while suspended, with explicit resync and no late revival" do
    consumer = frozen_consumer()
    {:ok, stream, state} = Notifier.subscribe_stream(state(), consumer, max_queue: 8)
    ref = Process.monitor(stream)
    :ok = :sys.suspend(stream)

    for n <- 1..1000, do: Notifier.broadcast_event(state, {:message_update, %{}, "delta #{n}"})
    assert {:message_queue_len, count} = Process.info(stream, :message_queue_len)
    assert count <= 9
    :ok = :sys.resume(stream)

    assert %{queue_size: 9, max_queue: 8, dropped: 1} = EventStream.stats(stream)
    Notifier.complete_event_streams(state, {:agent_end, [:canonical_answer]})
    Notifier.broadcast_event(state, {:agent_start})
    assert %{queue_size: 9} = EventStream.stats(stream)
    assert {:error, :overflow} = EventStream.result(stream)
    events = stream |> EventStream.events() |> Enum.to_list()

    assert List.last(events) ==
             {:session_event, "session-1", {:stream_resync, %{reason: :overflow}}}

    refute Enum.any?(events, &match?({:agent_end, _}, &1))

    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^stream, :normal}
  end

  test "replacement and dead subscriber cleanup remove monitors and fence old delivery" do
    consumer = frozen_consumer()
    {_unsubscribe, state} = Notifier.subscribe_direct(state(), consumer, self())
    [{^consumer, old_ref, old_delivery}] = state.event_listeners
    {_unsubscribe, state} = Notifier.subscribe_direct(state, consumer, self())
    assert [{^consumer, new_ref, _}] = state.event_listeners
    refute old_ref == new_ref
    assert LemonCore.Bus.Delivery.closed?(old_delivery)
    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^new_ref, :process, ^consumer, :killed}
    assert %{event_listeners: []} = Notifier.prune_subscribers(state, consumer, new_ref)
  end

  test "overflow retirement has a fixed deadline that late terminal events cannot extend" do
    {:ok, stream} =
      EventStream.start_link(
        owner: self(),
        max_queue: 1,
        drop_strategy: :resync,
        timeout: :infinity
      )

    assert :ok = EventStream.push(stream, :progress)
    assert {:error, :overflow} = EventStream.push(stream, :overflow)
    %{timeout_ref: deadline} = :sys.get_state(stream)
    assert is_reference(deadline)
    EventStream.complete(stream, [:late_terminal])
    EventStream.push_async(stream, :late_running)
    assert %{queue_size: 2} = EventStream.stats(stream)
    assert :sys.get_state(stream).timeout_ref == deadline
    assert {:error, :overflow} = EventStream.result(stream)
    ref = Process.monitor(stream)
    # Synchronized expiry injection exercises cleanup without a 30-second sleep.
    send(stream, :stream_timeout)
    assert_receive {:DOWN, ^ref, :process, ^stream, :normal}, 1000
  end

  defp state do
    %{session_manager: %{header: %{id: "session-1"}}, event_listeners: [], event_streams: %{}}
  end

  defp frozen_consumer do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :drain -> send(parent, {:drained, self(), collect([])})
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp drain(pid) do
    send(pid, :drain)
    assert_receive {:drained, ^pid, messages}
    messages
  end

  defp collect(acc) do
    receive do
      message -> collect([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
