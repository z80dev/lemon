defmodule LemonAi.EventStreamTest do
  use ExUnit.Case, async: true

  alias LemonAi.EventStream
  alias LemonAi.Types.AssistantMessage

  describe "bounded queue" do
    for {strategy, feedback, retained} <- [
          {:drop_oldest, :ok, [2, 3, 4]},
          {:drop_newest, :ok, [1, 2, 3]},
          {:error, {:error, :overflow}, [1, 2, 3]}
        ] do
      test "#{strategy} reports overflow and keeps the expected events in FIFO order" do
        stream = start_stream(max_queue: 3, drop_strategy: unquote(strategy))
        assert EventStream.stats(stream) == %{max_queue: 3, queue_size: 0, dropped: 0}
        for event <- 1..3, do: assert(:ok = EventStream.push(stream, event))
        assert EventStream.push(stream, 4) == unquote(feedback)
        assert EventStream.stats(stream) == %{max_queue: 3, queue_size: 3, dropped: 1}

        [first | remaining] = unquote(retained)
        assert Enum.take(EventStream.events(stream), 1) == [first]
        assert EventStream.stats(stream) == %{max_queue: 3, queue_size: 2, dropped: 1}
        assert :ok = EventStream.push(stream, :new_capacity)
        assert Enum.take(EventStream.events(stream), 3) == remaining ++ [:new_capacity]
        assert EventStream.stats(stream) == %{max_queue: 3, queue_size: 0, dropped: 1}
      end

      test "#{strategy} admits the terminal even when the queue is full" do
        stream = start_stream(max_queue: 2, drop_strategy: unquote(strategy))
        assert :ok = EventStream.push(stream, :was_oldest)
        assert :ok = EventStream.push(stream, :more_recent)
        message = %AssistantMessage{stop_reason: :stop}
        assert :ok = EventStream.complete(stream, message)
        assert EventStream.result(stream, 1_000) == {:ok, message}
        assert EventStream.stats(stream) == %{max_queue: 2, queue_size: 2, dropped: 1}
        assert Enum.to_list(EventStream.events(stream)) == [:more_recent, {:done, :stop, message}]
        assert EventStream.stats(stream) == %{max_queue: 2, queue_size: 0, dropped: 1}
      end
    end

    test "async overflow has no rejection reply, but counts toward dropped events" do
      stream = start_stream(max_queue: 2, drop_strategy: :error)
      assert :ok = EventStream.push(stream, :first)
      assert :ok = EventStream.push_async(stream, :second)
      assert :ok = EventStream.push_async(stream, :dropped)
      assert EventStream.stats(stream) == %{max_queue: 2, queue_size: 2, dropped: 1}
      assert Enum.take(EventStream.events(stream), 2) == [:first, :second]
    end

    test "push! makes overflow a terminal provider failure instead of silent loss" do
      stream = start_stream(max_queue: 1)
      assert :ok = EventStream.push!(stream, {:text_delta, 0, "accepted"})

      assert catch_throw(EventStream.push!(stream, :rejected)) ==
               {:event_stream_push_failed, :overflow}

      assert {:error, %AssistantMessage{error_message: "Event stream queue overflow"} = error} =
               EventStream.result(stream, 1_000)

      assert [{:error, :error, ^error}] = Enum.to_list(EventStream.events(stream))
    end

    test "resync overflow keeps its recovery marker through push! failure" do
      stream = start_stream(max_queue: 1, drop_strategy: :resync)
      assert :ok = EventStream.push!(stream, :accepted)

      assert catch_throw(EventStream.push!(stream, :rejected)) ==
               {:event_stream_push_failed, :overflow}

      assert EventStream.result(stream, 1_000) == {:error, :overflow}

      assert Enum.to_list(EventStream.events(stream)) == [
               :accepted,
               {:stream_resync, %{reason: :overflow}}
             ]
    end

    @tag :concurrency
    test "concurrent producers share the capacity and report each rejected push" do
      stream = start_stream(max_queue: 5, drop_strategy: :error)

      producers =
        for producer <- 1..4 do
          Task.async(fn ->
            for serial <- 1..25 do
              event = {producer, serial}
              {EventStream.push(stream, event), event}
            end
          end)
        end

      attempts = producers |> Task.await_many(1_000) |> List.flatten()
      accepted = for {:ok, event} <- attempts, do: event
      assert length(accepted) == 5
      assert Enum.count(attempts, &match?({{:error, :overflow}, _}, &1)) == 95
      assert EventStream.stats(stream) == %{max_queue: 5, queue_size: 5, dropped: 95}
      assert Enum.sort(Enum.take(EventStream.events(stream), 5)) == Enum.sort(accepted)
    end
  end

  describe "events and terminal results" do
    test "completion preserves FIFO arbitrary events and assistant, map and list payloads" do
      message = %AssistantMessage{stop_reason: :stop}
      accepted = [{:start, message}, :heartbeat, %{status: :working}, "chunk", 42]

      for {result, terminal} <- [
            {message, {:done, :stop, message}},
            {%{"stop_reason" => "length"}, {:done, "length", %{"stop_reason" => "length"}}},
            {[message], {:agent_end, [message]}},
            {[], {:agent_end, []}}
          ] do
        stream = start_stream()
        {:ok, subscription} = EventStream.subscribe_result(stream)
        for event <- accepted, do: assert(:ok = EventStream.push(stream, event))
        assert :ok = EventStream.complete(stream, result)
        assert :ok = EventStream.complete(stream, %AssistantMessage{stop_reason: :ignored})
        assert :ok = EventStream.error(stream, :ignored, nil)
        assert :ok = EventStream.push_async(stream, :ignored)

        assert catch_throw(EventStream.push!(stream, :late)) ==
                 {:event_stream_push_failed, :canceled}

        assert EventStream.result(stream, 1_000) == {:ok, result}
        assert Enum.to_list(EventStream.events(stream)) == accepted ++ [terminal]
        assert EventStream.result(stream, 1_000) == {:ok, result}
        assert_receive {:event_stream_result, ^subscription, {:ok, ^result}}, 1_000
        refute_receive {:event_stream_result, ^subscription, _}, 0
      end
    end

    test "error is the first terminal and preserves its provider or partial-state payload" do
      provider_error = %AssistantMessage{
        stop_reason: :error,
        error_message: "provider unavailable"
      }

      stream = start_stream()
      assert :ok = EventStream.error(stream, provider_error)
      assert :ok = EventStream.complete(stream, [])

      assert {:error,
              %AssistantMessage{error_message: "provider unavailable", error_details: details} =
                error} =
               EventStream.result(stream, 1_000)

      assert is_map(details)
      assert [{:error, :error, ^error}] = Enum.to_list(EventStream.events(stream))

      for partial <- [nil, %{messages: [:partial]}] do
        stream = start_stream()
        assert :ok = EventStream.error(stream, :tool_failed, partial)
        assert :ok = EventStream.complete(stream, [])
        assert EventStream.result(stream, 1_000) == {:error, :tool_failed, partial}
        assert Enum.to_list(EventStream.events(stream)) == [{:error, :tool_failed, partial}]
      end
    end

    test "events halts after yielding each supported pushed terminal" do
      for terminal <- [
            {:agent_end, []},
            {:error, :failed, nil},
            {:done, :stop, %{}},
            {:canceled, :user}
          ] do
        stream = start_stream()
        assert :ok = EventStream.push(stream, :before)
        assert :ok = EventStream.push(stream, terminal)
        assert :ok = EventStream.push(stream, :still_queued)
        assert Enum.to_list(EventStream.events(stream)) == [:before, terminal]
        assert EventStream.stats(stream).queue_size == 1
      end
    end

    test "collect_text concatenates async text deltas and skips non-text events" do
      stream = start_stream()
      assert :ok = EventStream.push_async(stream, {:text_delta, 0, "Hello"})
      assert :ok = EventStream.push_async(stream, {:thinking_delta, 0, "not shown"})
      assert :ok = EventStream.push_async(stream, {:text_delta, 0, " world"})
      assert :ok = EventStream.complete(stream, %AssistantMessage{stop_reason: :stop})
      assert EventStream.collect_text(stream) == "Hello world"
    end

    test "a result call can time out without closing the stream" do
      stream = start_stream()
      assert EventStream.result(stream, 0) == {:error, :timeout}
      assert :ok = EventStream.complete(stream, [])
      assert EventStream.result(stream, 1_000) == {:ok, []}
      assert [{:agent_end, []}] = Enum.to_list(EventStream.events(stream))
    end

    test "calls to a dead stream return boundary errors" do
      stream = start_stream()
      :ok = GenServer.stop(stream)
      assert EventStream.push(stream, :late) == {:error, :canceled}
      assert EventStream.result(stream, 1_000) == {:error, :stream_not_found}
      assert Enum.to_list(EventStream.events(stream)) == [{:canceled, :stream_closed}]
    end
  end

  describe "concurrent delivery" do
    @tag :concurrency
    test "blocked take requests receive events in registration order independently of all result waiters" do
      stream = start_stream()
      waiters = for _ <- 1..2, do: Task.async(fn -> EventStream.result(stream) end)
      await(fn -> :queue.len(:sys.get_state(stream).result_waiters) == 2 end)

      consumers =
        for index <- 1..3 do
          task = Task.async(fn -> Enum.take(EventStream.events(stream), 1) end)
          await(fn -> :queue.len(:sys.get_state(stream).take_waiters) == index end)
          task
        end

      assert :ok = EventStream.push(stream, :first)
      assert :ok = EventStream.push_async(stream, :second)
      assert EventStream.stats(stream).queue_size == 0
      assert Task.await(hd(consumers), 1_000) == [:first]
      assert Task.await(Enum.at(consumers, 1), 1_000) == [:second]
      assert :queue.len(:sys.get_state(stream).result_waiters) == 2
      assert :ok = EventStream.complete(stream, [])
      assert Task.await(List.last(consumers), 1_000) == [{:agent_end, []}]
      assert Task.await_many(waiters, 1_000) == [{:ok, []}, {:ok, []}]
    end

    @tag :concurrency
    test "concurrent producers preserve per-producer order and consumers partition events exactly once" do
      stream = start_stream(max_queue: 500)

      consumers =
        for _ <- 1..2, do: Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)

      await(fn -> :queue.len(:sys.get_state(stream).take_waiters) == 2 end)

      producers =
        for producer <- 1..4 do
          Task.async(fn ->
            for serial <- 1..100 do
              assert :ok = EventStream.push(stream, {producer, serial})
            end
          end)
        end

      Task.await_many(producers, 1_000)
      assert :ok = EventStream.complete(stream, [])
      batches = Task.await_many(consumers, 1_000)
      assert Enum.count(List.flatten(batches), &(&1 == {:agent_end, []})) == 1

      for producer <- 1..4 do
        sequences = for batch <- batches, do: for({^producer, serial} <- batch, do: serial)
        assert Enum.sort(List.flatten(sequences)) == Enum.to_list(1..100)
        assert Enum.all?(sequences, fn serials -> serials == Enum.sort(serials) end)
      end
    end

    @tag :concurrency
    test "a push racing completion is either delivered before the terminal or rejected" do
      stream = start_stream()
      producer = Task.async(fn -> EventStream.push(stream, :racing_event) end)
      assert :ok = EventStream.complete(stream, [])
      events = Enum.to_list(EventStream.events(stream))

      case Task.await(producer, 1_000) do
        :ok -> assert events == [:racing_event, {:agent_end, []}]
        {:error, :canceled} -> assert events == [{:agent_end, []}]
      end
    end

    test "a crashed reader does not stop delivery to another reader or result waiter" do
      stream = start_stream()

      {crasher, monitor} =
        spawn_monitor(fn ->
          [:first] = Enum.take(EventStream.events(stream), 1)
          exit(:reader_failed)
        end)

      await(fn -> :queue.len(:sys.get_state(stream).take_waiters) == 1 end)
      assert :ok = EventStream.push(stream, :first)
      assert_receive {:DOWN, ^monitor, :process, ^crasher, :reader_failed}, 1_000
      reader = Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)
      waiter = Task.async(fn -> EventStream.result(stream) end)
      await(fn -> :queue.len(:sys.get_state(stream).result_waiters) == 1 end)
      assert :ok = EventStream.push(stream, :second)
      assert :ok = EventStream.complete(stream, [])
      assert Task.await(reader, 1_000) == [:second, {:agent_end, []}]
      assert Task.await(waiter, 1_000) == {:ok, []}
    end

    @tag timeout: 15_000
    test "a queued push survives a suspended stream beyond the legacy five-second call timeout" do
      stream = start_stream()
      parent = self()
      :ok = :sys.suspend(stream)

      {producer, monitor} =
        spawn_monitor(fn -> send(parent, {:pushed, EventStream.push(stream, :heartbeat)}) end)

      on_exit(fn -> Process.exit(producer, :kill) end)

      try do
        await(fn ->
          {:messages, messages} = Process.info(stream, :messages)
          Enum.any?(messages, &match?({:"$gen_call", {^producer, _}, {:push, :heartbeat}}, &1))
        end)

        # Start the wait only once the call is queued; GenServer.call/2 would time out here.
        refute_receive {:DOWN, ^monitor, :process, ^producer, _}, 5_100
        refute_receive {:pushed, _}, 0
      after
        :ok = :sys.resume(stream)
      end

      assert_receive {:pushed, :ok}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 1_000
      assert Enum.take(EventStream.events(stream), 1) == [:heartbeat]
    end
  end

  defp start_stream(opts \\ []) do
    {:ok, stream} =
      EventStream.start_link(Keyword.merge([timeout: :infinity, idle_timeout: :infinity], opts))

    stream
  end

  defp await(predicate), do: await(predicate, System.monotonic_time(:millisecond) + 1_000)

  defp await(predicate, deadline) do
    unless predicate.() do
      assert System.monotonic_time(:millisecond) < deadline, "stream did not reach expected state"
      Process.sleep(1)
      await(predicate, deadline)
    end
  end
end
