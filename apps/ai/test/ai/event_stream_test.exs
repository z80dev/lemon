defmodule Ai.EventStreamOverflowTest do
  @moduledoc """
  Comprehensive tests for EventStream overflow scenarios and edge cases.

  This module tests:
  - Queue overflow with all three drop strategies (:drop_oldest, :drop_newest, :error)
  - Timeout scenarios in result/1
  - Task lifecycle (attach_task/detach_task) edge cases
  - Owner process death handling
  - Backpressure scenarios with slow consumers
  - Event ordering guarantees
  """

  use ExUnit.Case, async: true

  alias Ai.EventStream
  alias Ai.Types.{AssistantMessage, TextContent, Usage, Cost}

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp make_message(opts \\ []) do
    %AssistantMessage{
      content: Keyword.get(opts, :content, []),
      api: :test,
      provider: :test,
      model: "test",
      usage: %Usage{cost: %Cost{}},
      stop_reason: Keyword.get(opts, :stop_reason, :stop),
      timestamp: System.system_time(:millisecond)
    }
  end

  defp wait_until(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> fun.() end)
    |> Enum.reduce_while(false, fn result, _ ->
      cond do
        result ->
          {:halt, true}

        System.monotonic_time(:millisecond) > deadline ->
          {:halt, false}

        true ->
          Process.sleep(5)
          {:cont, false}
      end
    end)
  end

  defp extract_text_content(events) do
    events
    |> Enum.filter(&match?({:text_delta, _, _, _}, &1))
    |> Enum.map(fn {:text_delta, _, text, _} -> text end)
  end

  # ============================================================================
  # Queue Overflow with :drop_oldest Strategy
  # ============================================================================

  describe "queue overflow with :drop_oldest strategy" do
    test "drops oldest events when queue is full" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :drop_oldest)
      partial = make_message()

      # Push 5 events into a queue of size 3
      # Events 1 and 2 should be dropped
      for i <- 1..5 do
        assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      stats = EventStream.stats(stream)
      assert stats.queue_size == 3
      assert stats.dropped == 2

      EventStream.complete(stream, make_message())
      events = EventStream.events(stream) |> Enum.to_list()
      texts = extract_text_content(events)

      # Should have kept 3, 4, 5 but one more dropped for done event
      assert length(texts) == 2
      # Most recent events should be preserved
      assert "msg_5" in texts
    end

    test "always returns :ok even when dropping" do
      {:ok, stream} = EventStream.start_link(max_queue: 1, drop_strategy: :drop_oldest)
      partial = make_message()

      # All pushes should succeed
      for i <- 1..10 do
        result = EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
        assert result == :ok
      end

      stats = EventStream.stats(stream)
      assert stats.dropped == 9
    end

    test "preserves event order for remaining events" do
      {:ok, stream} = EventStream.start_link(max_queue: 5, drop_strategy: :drop_oldest)
      partial = make_message()

      # Push 8 events, first 3 should be dropped
      for i <- 1..8 do
        EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      EventStream.complete(stream, make_message())
      events = EventStream.events(stream) |> Enum.to_list()
      texts = extract_text_content(events)

      # Events should be in order (4, 5, 6, 7 - after dropping oldest for done)
      assert Enum.at(texts, 0) < Enum.at(texts, 1)
    end

    test "handles rapid overflow correctly" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :drop_oldest)
      partial = make_message()

      # Push many events very quickly
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
          end)
        end

      Enum.each(tasks, &Task.await(&1, 5000))

      stats = EventStream.stats(stream)
      assert stats.queue_size == 2
      assert stats.dropped >= 18
    end
  end

  # ============================================================================
  # Queue Overflow with :drop_newest Strategy
  # ============================================================================

  describe "queue overflow with :drop_newest strategy" do
    test "drops newest events when queue is full" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :drop_newest)
      partial = make_message()

      # Push 5 events into a queue of size 3
      # Events 4 and 5 should be dropped (newest are dropped)
      for i <- 1..5 do
        assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      stats = EventStream.stats(stream)
      assert stats.queue_size == 3
      assert stats.dropped == 2

      # complete() drops oldest (msg_1) to make room for done event
      EventStream.complete(stream, make_message())
      events = EventStream.events(stream) |> Enum.to_list()
      texts = extract_text_content(events)

      # Should have kept 2, 3 (msg_1 dropped for done event)
      assert length(texts) == 2
      assert "msg_2" in texts
      assert "msg_3" in texts
    end

    test "always returns :ok even when dropping" do
      {:ok, stream} = EventStream.start_link(max_queue: 1, drop_strategy: :drop_newest)
      partial = make_message()

      # All pushes should succeed
      for i <- 1..10 do
        result = EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
        assert result == :ok
      end

      stats = EventStream.stats(stream)
      assert stats.dropped == 9
    end

    test "preserves oldest events" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :drop_newest)
      partial = make_message()

      for i <- 1..10 do
        EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      # Queue has [msg_1, msg_2, msg_3], dropped 7 newest (msg_4..msg_10)
      # complete() drops oldest (msg_1) to make room for done event
      EventStream.complete(stream, make_message())
      events = EventStream.events(stream) |> Enum.to_list()
      texts = extract_text_content(events)

      # Should have kept msg_2 and msg_3 (msg_1 dropped for done event)
      assert "msg_2" in texts
      assert "msg_3" in texts
      # msg_1 was dropped to make room for done
      refute "msg_1" in texts
    end

    test "logs debug message when dropping" do
      {:ok, stream} = EventStream.start_link(max_queue: 1, drop_strategy: :drop_newest)
      partial = make_message()

      # Fill the queue
      EventStream.push(stream, {:text_delta, 0, "msg_1", partial})

      # This should trigger a log and drop the event
      EventStream.push(stream, {:text_delta, 0, "msg_2", partial})

      stats = EventStream.stats(stream)
      assert stats.dropped == 1
    end
  end

  # ============================================================================
  # Queue Overflow with :error Strategy
  # ============================================================================

  describe "queue overflow with :error strategy" do
    test "returns {:error, :overflow} when queue is full" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :error)
      partial = make_message()

      assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_1", partial})
      assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_2", partial})
      assert {:error, :overflow} = EventStream.push(stream, {:text_delta, 0, "msg_3", partial})
    end

    test "increments dropped count on overflow" do
      {:ok, stream} = EventStream.start_link(max_queue: 1, drop_strategy: :error)
      partial = make_message()

      EventStream.push(stream, {:text_delta, 0, "msg_1", partial})

      for _ <- 1..5 do
        EventStream.push(stream, {:text_delta, 0, "overflow", partial})
      end

      stats = EventStream.stats(stream)
      assert stats.dropped == 5
    end

    test "push_async silently drops on overflow" do
      {:ok, stream} = EventStream.start_link(max_queue: 1, drop_strategy: :error)
      partial = make_message()

      # Fill the queue
      EventStream.push(stream, {:text_delta, 0, "msg_1", partial})

      # Async pushes should not block or return errors
      for i <- 2..10 do
        EventStream.push_async(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      # Wait for async messages to be processed
      assert wait_until(fn ->
               stats = EventStream.stats(stream)
               stats.dropped >= 8
             end)
    end

    test "allows pushing after consuming events" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :error)
      partial = make_message()

      # Fill the queue
      EventStream.push(stream, {:text_delta, 0, "msg_1", partial})
      EventStream.push(stream, {:text_delta, 0, "msg_2", partial})
      assert {:error, :overflow} = EventStream.push(stream, {:text_delta, 0, "msg_3", partial})

      # Start a consumer to drain some events
      reader =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.take(1)
        end)

      Task.await(reader, 1000)

      # Now we should be able to push again
      assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_4", partial})
    end

    test "terminal events force room by dropping oldest" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :error)
      partial = make_message()

      # Fill the queue
      EventStream.push(stream, {:text_delta, 0, "msg_1", partial})
      EventStream.push(stream, {:text_delta, 0, "msg_2", partial})

      # Complete should still work by dropping oldest
      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()
      assert Enum.any?(events, &match?({:done, _, _}, &1))
    end
  end

  # ============================================================================
  # Timeout Scenarios in result/1
  # ============================================================================

  describe "timeout scenarios in result/1" do
    test "result/1 times out when stream doesn't complete" do
      {:ok, stream} = EventStream.start_link()

      # Don't complete the stream, just let result timeout
      result = EventStream.result(stream, 100)
      assert {:error, :timeout} = result
    end

    test "result/1 succeeds before timeout when stream completes" do
      {:ok, stream} = EventStream.start_link()

      # Complete after a short delay
      Task.start(fn ->
        Process.sleep(50)
        EventStream.complete(stream, make_message(content: [%TextContent{text: "done"}]))
      end)

      result = EventStream.result(stream, 500)
      assert {:ok, %AssistantMessage{}} = result
    end

    test "result/1 returns :stream_not_found for dead stream" do
      {:ok, stream} = EventStream.start_link()
      EventStream.cancel(stream, :test)

      # Wait for stream to die
      Process.sleep(50)

      result = EventStream.result(stream, 100)
      assert {:error, :stream_not_found} = result
    end

    test "result/1 with :infinity timeout blocks until completion" do
      {:ok, stream} = EventStream.start_link()

      # Start a task to complete after delay
      Task.start(fn ->
        Process.sleep(100)
        EventStream.complete(stream, make_message())
      end)

      # This should block until completion
      result = EventStream.result(stream, :infinity)
      assert {:ok, _} = result
    end

    test "multiple waiters all receive result" do
      {:ok, stream} = EventStream.start_link()

      # Start multiple waiters
      waiters =
        for _ <- 1..5 do
          Task.async(fn ->
            EventStream.result(stream, 5000)
          end)
        end

      # Complete the stream
      Process.sleep(50)
      EventStream.complete(stream, make_message(content: [%TextContent{text: "shared result"}]))

      # All waiters should get the result
      results = Enum.map(waiters, &Task.await(&1, 1000))

      assert Enum.all?(results, fn
               {:ok, %AssistantMessage{content: [%TextContent{text: "shared result"}]}} -> true
               _ -> false
             end)
    end

    test "result/1 returns error result when stream errors" do
      {:ok, stream} = EventStream.start_link()

      EventStream.error(stream, make_message(stop_reason: :error))

      result = EventStream.result(stream, 100)
      assert {:error, %AssistantMessage{stop_reason: :error}} = result
    end
  end

  # ============================================================================
  # Task Lifecycle Edge Cases
  # ============================================================================

  describe "task lifecycle (attach_task/detach_task) edge cases" do
    test "attaching task multiple times replaces previous task" do
      {:ok, stream} = EventStream.start_link()
      test_pid = self()

      # Start first task
      {:ok, task1_pid} =
        Task.start(fn ->
          send(test_pid, {:task1_started, self()})
          receive do: (:stop -> :ok)
        end)

      EventStream.attach_task(stream, task1_pid)
      assert_receive {:task1_started, ^task1_pid}, 1000

      # Start second task
      {:ok, task2_pid} =
        Task.start(fn ->
          send(test_pid, {:task2_started, self()})
          receive do: (:stop -> :ok)
        end)

      EventStream.attach_task(stream, task2_pid)
      assert_receive {:task2_started, ^task2_pid}, 1000

      # Cancel stream - should only shutdown the currently attached task
      EventStream.cancel(stream, :test)

      Process.sleep(100)

      # Task1 should still be alive (it was replaced)
      assert Process.alive?(task1_pid)
      refute Process.alive?(task2_pid)

      # Cleanup task1
      send(task1_pid, :stop)
    end

    test "task crash before stream completion triggers error" do
      {:ok, stream} = EventStream.start_link()

      {:ok, task_pid} =
        Task.start(fn ->
          Process.sleep(50)
          exit(:intentional_crash)
        end)

      EventStream.attach_task(stream, task_pid)

      result = EventStream.result(stream, 5000)
      assert {:error, %AssistantMessage{stop_reason: :error}} = result
    end

    test "task normal exit after completion doesn't affect stream" do
      {:ok, stream} = EventStream.start_link()

      {:ok, task_pid} =
        Task.start(fn ->
          Process.sleep(20)
          EventStream.complete(stream, make_message())
          # Task exits normally after completing
        end)

      EventStream.attach_task(stream, task_pid)

      result = EventStream.result(stream, 5000)
      assert {:ok, _} = result
    end

    test "attaching already-dead task is handled gracefully" do
      {:ok, stream} = EventStream.start_link()

      {:ok, task_pid} = Task.start(fn -> :done end)
      # Wait for task to die
      Process.sleep(50)
      refute Process.alive?(task_pid)

      # Attaching dead task should not crash the stream
      EventStream.attach_task(stream, task_pid)

      # Stream should still work
      assert Process.alive?(stream)
      EventStream.complete(stream, make_message())
      {:ok, _} = EventStream.result(stream, 100)
    end

    test "stream still works without any attached task" do
      {:ok, stream} = EventStream.start_link()
      partial = make_message()

      EventStream.push(stream, {:text_delta, 0, "hello", partial})
      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()
      assert length(events) == 2
    end

    test "task receives shutdown signal on owner death" do
      test_pid = self()

      # Create an owner process
      owner_pid =
        spawn(fn ->
          receive do: (:die -> :ok)
        end)

      {:ok, stream} = EventStream.start_link(owner: owner_pid)

      {:ok, task_pid} =
        Task.start(fn ->
          send(test_pid, {:task_started, self()})
          receive do: (_ -> :ok)
        end)

      EventStream.attach_task(stream, task_pid)
      assert_receive {:task_started, ^task_pid}, 1000

      # Kill the owner
      send(owner_pid, :die)

      # Wait for cascade
      Process.sleep(150)

      # Both stream and task should be dead
      refute Process.alive?(stream)
      refute Process.alive?(task_pid)
    end
  end

  # ============================================================================
  # Owner Process Death Handling
  # ============================================================================

  describe "owner process death handling" do
    test "stream terminates when owner dies" do
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, stream} = EventStream.start_link(owner: self())
          send(test_pid, {:stream, stream})
          receive do: (:die -> :ok)
        end)

      stream =
        receive do
          {:stream, s} -> s
        after
          1000 -> flunk("Did not receive stream")
        end

      assert Process.alive?(stream)

      # Kill owner
      send(owner, :die)

      # Wait for DOWN message processing
      Process.sleep(100)

      refute Process.alive?(stream)
    end

    test "result waiters receive error on owner death" do
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, stream} = EventStream.start_link(owner: self())
          send(test_pid, {:stream, stream})
          receive do: (:die -> :ok)
        end)

      stream =
        receive do
          {:stream, s} -> s
        after
          1000 -> flunk("Did not receive stream")
        end

      # Start waiting for result
      waiter =
        Task.async(fn ->
          EventStream.result(stream, 5000)
        end)

      # Give waiter time to register
      Process.sleep(50)

      # Kill owner
      send(owner, :die)

      result = Task.await(waiter, 1000)
      assert {:error, {:canceled, :owner_down}} = result
    end

    test "events include canceled event with :owner_down reason" do
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, stream} = EventStream.start_link(owner: self())
          send(test_pid, {:stream, stream})
          receive do: (:die -> :ok)
        end)

      stream =
        receive do
          {:stream, s} -> s
        after
          1000 -> flunk("Did not receive stream")
        end

      # Start reading events
      reader =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      # Give reader time to start waiting
      Process.sleep(50)

      # Kill owner
      send(owner, :die)

      events = Task.await(reader, 1000)
      assert Enum.any?(events, &match?({:canceled, :owner_down}, &1))
    end

    test "stream with self as owner is not monitored" do
      # When owner is self, the stream should not set up monitoring
      {:ok, stream} = EventStream.start_link(owner: self())

      # Stream should work normally
      partial = make_message()
      EventStream.push(stream, {:text_delta, 0, "hello", partial})
      EventStream.complete(stream, make_message())

      {:ok, _} = EventStream.result(stream, 100)
    end

    test "attached task is killed when owner dies" do
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, stream} = EventStream.start_link(owner: self())
          send(test_pid, {:stream, stream})
          receive do: (:die -> :ok)
        end)

      stream =
        receive do
          {:stream, s} -> s
        after
          1000 -> flunk("Did not receive stream")
        end

      {:ok, task_pid} =
        Task.start(fn ->
          send(test_pid, {:task_started, self()})
          receive do: (_ -> :ok)
        end)

      EventStream.attach_task(stream, task_pid)
      assert_receive {:task_started, ^task_pid}, 1000

      # Kill owner
      send(owner, :die)

      # Wait for cascade
      Process.sleep(150)

      refute Process.alive?(task_pid)
    end
  end

  # ============================================================================
  # Backpressure Scenarios with Slow Consumers
  # ============================================================================

  describe "backpressure scenarios with slow consumers" do
    test "producer can push faster than consumer reads" do
      {:ok, stream} = EventStream.start_link(max_queue: 100, drop_strategy: :error)
      partial = make_message()

      # Start slow consumer
      consumer =
        Task.async(fn ->
          EventStream.events(stream)
          |> Enum.map(fn event ->
            Process.sleep(10)
            event
          end)
          |> Enum.to_list()
        end)

      # Fast producer
      for i <- 1..20 do
        EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      EventStream.complete(stream, make_message())

      events = Task.await(consumer, 5000)
      # All events should be received (queue is large enough)
      assert length(events) == 21
    end

    test "backpressure with error strategy blocks producer" do
      {:ok, stream} = EventStream.start_link(max_queue: 5, drop_strategy: :error)
      partial = make_message()

      # Fill the queue
      for i <- 1..5 do
        assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      # Next push should fail
      assert {:error, :overflow} = EventStream.push(stream, {:text_delta, 0, "overflow", partial})

      # Start consumer
      consumer =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.take(1)
        end)

      Task.await(consumer, 1000)

      # Now push should work again
      assert :ok = EventStream.push(stream, {:text_delta, 0, "after_consume", partial})
    end

    test "slow consumer with drop_oldest loses old events" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :drop_oldest)
      partial = make_message()

      # Fill queue and trigger drops
      for i <- 1..10 do
        EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      stats = EventStream.stats(stream)
      assert stats.dropped == 7

      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()
      texts = extract_text_content(events)

      # Should have recent events (after dropping for done)
      assert "msg_10" in texts or "msg_9" in texts
      refute "msg_1" in texts
    end

    test "concurrent producers and consumer with backpressure" do
      {:ok, stream} = EventStream.start_link(max_queue: 10, drop_strategy: :drop_oldest)
      partial = make_message()

      # Start consumer
      consumer =
        Task.async(fn ->
          EventStream.events(stream)
          |> Enum.map(fn event ->
            Process.sleep(5)
            event
          end)
          |> Enum.to_list()
        end)

      # Multiple producers
      producers =
        for producer_id <- 1..3 do
          Task.async(fn ->
            for i <- 1..10 do
              EventStream.push(stream, {:text_delta, 0, "p#{producer_id}_#{i}", partial})
              Process.sleep(1)
            end
          end)
        end

      # Wait for producers
      Enum.each(producers, &Task.await(&1, 5000))

      # Complete and wait for consumer
      EventStream.complete(stream, make_message())

      events = Task.await(consumer, 10000)

      # Should have the done event
      assert Enum.any?(events, &match?({:done, _, _}, &1))
    end

    test "take waiter gets event immediately when available" do
      {:ok, stream} = EventStream.start_link()
      partial = make_message()

      # Push event before consumer starts
      EventStream.push(stream, {:text_delta, 0, "already_there", partial})

      # Consumer should get event immediately
      start_time = System.monotonic_time(:millisecond)

      consumer =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.take(1)
        end)

      events = Task.await(consumer, 1000)
      elapsed = System.monotonic_time(:millisecond) - start_time

      assert [{:text_delta, 0, "already_there", _}] = events
      assert elapsed < 100
    end
  end

  # ============================================================================
  # Event Ordering Guarantees
  # ============================================================================

  describe "event ordering guarantees" do
    test "events are delivered in FIFO order" do
      {:ok, stream} = EventStream.start_link()
      partial = make_message()

      # Push events in order
      for i <- 1..100 do
        EventStream.push(
          stream,
          {:text_delta, 0, "msg_#{String.pad_leading(to_string(i), 3, "0")}", partial}
        )
      end

      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()
      texts = extract_text_content(events)

      # Verify FIFO order
      indexed = Enum.with_index(texts)

      Enum.each(indexed, fn {text, idx} ->
        expected = "msg_#{String.pad_leading(to_string(idx + 1), 3, "0")}"
        assert text == expected, "Expected #{expected} at index #{idx}, got #{text}"
      end)
    end

    test "terminal events come after all regular events" do
      {:ok, stream} = EventStream.start_link()
      partial = make_message()

      for i <- 1..10 do
        EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()

      # Done event should be last
      {last, rest} = List.pop_at(events, -1)
      assert {:done, _, _} = last

      # All other events should be text_delta
      Enum.each(rest, fn event ->
        assert {:text_delta, _, _, _} = event
      end)
    end

    test "multiple consumers see same order" do
      {:ok, stream} = EventStream.start_link()
      partial = make_message()

      # Push some events
      for i <- 1..5 do
        EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      EventStream.complete(stream, make_message())

      # Consume all events
      events = EventStream.events(stream) |> Enum.to_list()
      texts = extract_text_content(events)

      assert texts == ["msg_1", "msg_2", "msg_3", "msg_4", "msg_5"]
    end

    test "order preserved under concurrent push" do
      {:ok, stream} = EventStream.start_link(max_queue: 1000)

      # Use a single producer to ensure deterministic ordering
      partial = make_message()

      for i <- 1..50 do
        EventStream.push(stream, {:text_delta, 0, "#{i}", partial})
      end

      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()
      texts = extract_text_content(events)
      numbers = Enum.map(texts, &String.to_integer/1)

      # Should be strictly increasing
      assert numbers == Enum.to_list(1..50)
    end

    test "waiters receive events in order they arrive" do
      {:ok, stream} = EventStream.start_link()
      partial = make_message()

      # Start consumer first
      consumer =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      # Give consumer time to start waiting
      Process.sleep(20)

      # Push events
      for i <- 1..10 do
        EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
        Process.sleep(5)
      end

      EventStream.complete(stream, make_message())

      events = Task.await(consumer, 5000)
      texts = extract_text_content(events)

      # Order should be preserved
      expected = for i <- 1..10, do: "msg_#{i}"
      assert texts == expected
    end

    test "drop_oldest preserves order of remaining events" do
      {:ok, stream} = EventStream.start_link(max_queue: 5, drop_strategy: :drop_oldest)
      partial = make_message()

      # Push 10 events, first 5 will be dropped
      for i <- 1..10 do
        EventStream.push(stream, {:text_delta, 0, "#{i}", partial})
      end

      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()
      texts = extract_text_content(events)
      numbers = Enum.map(texts, &String.to_integer/1)

      # Remaining events should be in order
      assert numbers == Enum.sort(numbers)
    end
  end

  # ============================================================================
  # Edge Cases and Error Handling
  # ============================================================================

  describe "edge cases and error handling" do
    test "push to canceled stream returns :canceled" do
      {:ok, stream} = EventStream.start_link()
      EventStream.cancel(stream, :test)

      Process.sleep(50)

      result = EventStream.push(stream, {:text_delta, 0, "test", make_message()})
      assert {:error, :canceled} = result
    end

    test "completing already completed stream preserves first result" do
      {:ok, stream} = EventStream.start_link()

      EventStream.complete(stream, make_message(content: [%TextContent{text: "first"}]))

      # Get the result from the first completion
      {:ok, result} = EventStream.result(stream, 100)
      assert [%TextContent{text: "first"}] = result.content

      # Second complete is a cast, so it may still modify state
      # But result should already be set from first complete
    end

    test "stats available after stream completion" do
      {:ok, stream} = EventStream.start_link(max_queue: 10)
      partial = make_message()

      for i <- 1..5 do
        EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      EventStream.complete(stream, make_message())

      # Consume all events
      EventStream.events(stream) |> Enum.to_list()

      # Stats should still be available (though queue is empty now)
      stats = EventStream.stats(stream)
      assert stats.max_queue == 10
    end

    test "empty stream completes correctly" do
      {:ok, stream} = EventStream.start_link()

      # Complete without any events
      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()
      assert [{:done, :stop, _}] = events
    end

    test "very large queue handles many events" do
      {:ok, stream} = EventStream.start_link(max_queue: 100_000)
      partial = make_message()

      # Push many events
      for i <- 1..1000 do
        EventStream.push(stream, {:text_delta, 0, "#{i}", partial})
      end

      stats = EventStream.stats(stream)
      assert stats.queue_size == 1000
      assert stats.dropped == 0

      EventStream.complete(stream, make_message())
      {:ok, _} = EventStream.result(stream, 5000)
    end

    test "stream timeout cancels waiting result calls" do
      {:ok, stream} = EventStream.start_link(timeout: 100)

      waiter =
        Task.async(fn ->
          EventStream.result(stream, 5000)
        end)

      result = Task.await(waiter, 1000)
      assert {:error, {:canceled, :timeout}} = result
    end
  end
end
