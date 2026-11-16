defmodule CodingAgent.Session.NotifierBackpressureTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.{EventLog, Notifier}
  alias LemonAgent.EventStream

  test "adjacent text from different indices cannot merge" do
    consumer = frozen_consumer()
    {_unsubscribe, state} = Notifier.subscribe_direct(state(), consumer, self())

    for {index, text} <- [{0, "a"}, {1, "b"}, {1, "c"}] do
      Notifier.broadcast_event(state, {:message_update, {:text_delta, index, text}})
    end

    Notifier.flush_pending()

    assert [
             {:session_event, "session-1", {:message_update, {:text_delta, 0, "a"}}, first},
             {:session_event, "session-1", {:message_update, {:text_delta, 1, "bc"}}, last}
           ] = drain(consumer)

    assert first["seq"] == 1
    assert last["seq"] == 3
  end

  test "adjacent text batches preserve boundaries, latest cursor, and uncoalesced replay" do
    consumer = frozen_consumer()
    {_unsubscribe, state} = Notifier.subscribe_direct(state(), consumer, self())
    initial = EventLog.cursor(state.event_log)
    call = %LemonAi.Types.ToolCall{id: "call", name: "read", arguments: %{}}

    events = [
      {:message_start, %LemonAi.Types.AssistantMessage{}},
      {:message_update, {:text_start, 0}},
      {:message_update, {:text_delta, 0, "hel"}},
      {:message_update, {:text_delta, 0, "lo"}},
      {:message_update, {:text_end, 0, "hello"}},
      {:message_update, {:tool_call_start, 1, call}},
      {:message_update, {:tool_call_delta, 1, "{"}},
      {:message_update, {:tool_call_delta, 1, "}"}},
      {:message_update, {:tool_call_end, 1, call}},
      {:agent_end, []}
    ]

    Enum.each(events, &Notifier.broadcast_event(state, &1))
    Notifier.flush_pending()
    delivered = drain(consumer)

    assert Enum.map(delivered, &elem(&1, 2)) ==
             Enum.take(events, 2) ++
               [{:message_update, {:text_delta, 0, "hello"}}] ++ Enum.drop(events, 4)

    assert elem(Enum.at(delivered, 2), 3)["seq"] == 4
    assert {:ok, replay} = EventLog.replay(state.event_log, initial, 100)
    assert Enum.map(replay.events, & &1.event) == events
    assert replay.cursor["seq"] == length(events)
  end

  test "each subscriber batches within its own count budget and terminal flushes first" do
    small = frozen_consumer()
    large = frozen_consumer()
    {_unsubscribe, state} = Notifier.subscribe_direct(state(), small, self(), max_queue: 2)
    {_unsubscribe, state} = Notifier.subscribe_direct(state, large, self(), max_queue: 8)

    for text <- ["a", "b", "c"] do
      Notifier.broadcast_event(state, {:message_update, {:text_delta, 0, text}})
    end

    # The first subscriber has already filled its two-fragment batch.
    assert {:message_queue_len, 1} = Process.info(small, :message_queue_len)
    assert {:message_queue_len, 0} = Process.info(large, :message_queue_len)
    Notifier.flush_pending()

    assert Enum.map(drain(small), &elem(&1, 2)) ==
             [{:message_update, {:text_delta, 0, "ab"}}, {:message_update, {:text_delta, 0, "c"}}]

    assert [{:session_event, "session-1", {:message_update, {:text_delta, 0, "abc"}}, _}] =
             drain(large)

    {:ok, stream, state} = Notifier.subscribe_stream(state(), self(), [])
    Notifier.broadcast_event(state, {:message_update, {:text_delta, 0, "before terminal"}})
    Notifier.complete_event_streams(state, {:agent_end, []})

    assert [
             {:session_event, "session-1", {:message_update, {:text_delta, 0, "before terminal"}},
              _},
             {:agent_end, []}
           ] = stream |> EventStream.events() |> Enum.to_list()
  end

  test "byte budgets split text batches and oversized deltas fence without late revival" do
    consumer = frozen_consumer()

    {_unsubscribe, state} =
      Notifier.subscribe_direct(state(), consumer, self(), max_bytes: 512, max_queue: 8)

    text = String.duplicate("a", 180)

    for _ <- 1..3, do: Notifier.broadcast_event(state, {:message_update, {:text_delta, 0, text}})
    Notifier.flush_pending()
    messages = drain(consumer)

    assert Enum.map_join(messages, fn {:session_event, _,
                                       {:message_update, {:text_delta, 0, delta}}, _} ->
             delta
           end) == String.duplicate(text, 3)

    assert Enum.all?(messages, &(:erlang.external_size(&1) <= 512))

    oversized = frozen_consumer()

    {_unsubscribe, state} =
      Notifier.subscribe_direct(state(), oversized, self(), max_bytes: 512)

    Notifier.broadcast_event(
      state,
      {:message_update, {:text_delta, 0, String.duplicate("x", 1024)}}
    )

    Notifier.broadcast_event(state, {:message_update, {:text_delta, 0, "late"}})
    Notifier.flush_pending()

    assert [{:session_event, "session-1", {:stream_resync, %{reason: :overflow}}, nil}] =
             drain(oversized)
  end

  test "replacing a subscriber discards its undelivered text batch" do
    consumer = frozen_consumer()
    {_unsubscribe, state} = Notifier.subscribe_direct(state(), consumer, self())
    Notifier.broadcast_event(state, {:message_update, {:text_delta, 0, "stale"}})
    {_unsubscribe, state} = Notifier.subscribe_direct(state, consumer, self())
    Notifier.broadcast_event(state, {:message_update, {:text_delta, 0, "fresh"}})
    Notifier.flush_pending()

    assert [{:session_event, "session-1", {:message_update, {:text_delta, 0, "fresh"}}, _}] =
             drain(consumer)
  end

  test "quiet session subscriptions do not inherit a provider inactivity timer" do
    {:ok, stream, _state} = Notifier.subscribe_stream(state(), self(), timeout: 5_000)
    timers = :sys.get_state(stream)
    assert timers.idle_timeout == :infinity
    assert timers.idle_timeout_ref == nil
    assert Process.read_timer(timers.timeout_ref) > 0
    EventStream.cancel(stream, :test_cleanup)
  end

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
    terminal = {:agent_end, [%{role: :assistant, content: "canonical_answer"}]}
    assert :ok = Notifier.broadcast_event(state, terminal)
    assert :ok = Notifier.complete_event_streams(state, terminal)
    assert :ok = Notifier.complete_event_streams(state, {:canceled, :late_cancel})
    assert :ok = Notifier.broadcast_event(state, {:agent_start})
    assert {:message_queue_len, 10} = Process.info(consumer, :message_queue_len)

    messages = drain(consumer)

    assert Enum.count(
             messages,
             &match?({:session_event, "session-1", {:tool_execution_update, _, _, _, _}, _}, &1)
           ) == 8

    assert Enum.count(
             messages,
             &(&1 == {:session_event, "session-1", {:stream_resync, %{reason: :overflow}}, nil})
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

    for n <- 1..1000,
        do: Notifier.broadcast_event(state, {:message_update, {:text_delta, 0, "delta #{n}"}})

    assert {:message_queue_len, count} = Process.info(stream, :message_queue_len)
    assert count <= 9
    :ok = :sys.resume(stream)

    assert %{queue_size: 9, max_queue: 8, dropped: 1} = EventStream.stats(stream)

    Notifier.complete_event_streams(
      state,
      {:agent_end, [%{role: :assistant, content: "canonical_answer"}]}
    )

    Notifier.broadcast_event(state, {:agent_start})
    assert %{queue_size: 9} = EventStream.stats(stream)
    assert {:error, :overflow} = EventStream.result(stream)
    events = stream |> EventStream.events() |> Enum.to_list()

    assert List.last(events) ==
             {:session_event, "session-1", {:stream_resync, %{reason: :overflow}}, nil}

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
    %{
      session_manager: %{header: %{id: "session-1"}},
      session_key: nil,
      run_id: nil,
      event_log: EventLog.new("session-1", nil, nil, System.tmp_dir!()),
      event_listeners: [],
      event_streams: %{}
    }
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
