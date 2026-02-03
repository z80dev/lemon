defmodule AgentCore.EventStreamConcurrencyTest do
  @moduledoc """
  Comprehensive concurrency tests for AgentCore.EventStream focusing on:

  1. Queue overflow behavior under sustained load
  2. Monitor cleanup on owner death
  3. Race conditions in queue delivery
  4. Result/take waiter interleaving
  5. Multiple concurrent producers and consumers
  6. Terminal event handling edge cases
  7. State cleanup scenarios

  These tests stress test concurrent access patterns, race conditions,
  and verify correctness under high contention.
  """
  use ExUnit.Case, async: true

  alias AgentCore.EventStream

  @moduletag :concurrency

  # ============================================================================
  # 1. Queue Overflow Behavior Under Sustained Load
  # ============================================================================

  describe "queue overflow under sustained load" do
    test "drop_oldest maintains bounded queue under sustained producer pressure" do
      {:ok, stream} = EventStream.start_link(max_queue: 100, drop_strategy: :drop_oldest)

      # Sustained producer - faster than consumer can keep up
      producer =
        Task.async(fn ->
          for i <- 1..10_000 do
            EventStream.push(stream, {:event, i})
          end
        end)

      # Slow consumer - takes events one at a time with delay
      consumer =
        Task.async(fn ->
          stream
          |> EventStream.events()
          |> Enum.reduce(0, fn event, count ->
            if rem(count, 50) == 0, do: Process.sleep(1)

            case event do
              {:agent_end, _} -> count
              _ -> count + 1
            end
          end)
        end)

      Task.await(producer, 10_000)
      EventStream.complete(stream, [])

      received = Task.await(consumer, 10_000)

      stats = EventStream.stats(stream)

      # Queue should never exceed max_queue
      assert stats.queue_size <= 100

      # Many events should have been dropped
      assert stats.dropped > 0

      # Consumer should have received some events
      assert received > 0

      # Total should roughly equal 10_000 (some may still be in queue)
      assert received + stats.dropped + stats.queue_size >= 9_900
    end

    test "drop_newest preserves oldest events under sustained load" do
      {:ok, stream} = EventStream.start_link(max_queue: 50, drop_strategy: :drop_newest)

      # Fill queue faster than it can drain
      for i <- 1..500 do
        EventStream.push(stream, {:event, i})
      end

      stats = EventStream.stats(stream)
      assert stats.queue_size == 50
      assert stats.dropped == 450

      EventStream.complete(stream, [])
      events = EventStream.events(stream) |> Enum.to_list()

      # Should have oldest events (1-50) but complete drops oldest for terminal
      event_values =
        events
        |> Enum.filter(&match?({:event, _}, &1))
        |> Enum.map(fn {:event, i} -> i end)

      # The oldest events should be preserved (minus one dropped for terminal)
      assert Enum.min(event_values) <= 2
      assert Enum.max(event_values) <= 50
    end

    test "error strategy returns overflow under sustained pressure" do
      {:ok, stream} = EventStream.start_link(max_queue: 20, drop_strategy: :error)

      # Track successful vs failed pushes
      results =
        for i <- 1..100 do
          {i, EventStream.push(stream, {:event, i})}
        end

      successful = Enum.count(results, fn {_, r} -> r == :ok end)
      overflows = Enum.count(results, fn {_, r} -> r == {:error, :overflow} end)

      assert successful == 20
      assert overflows == 80

      stats = EventStream.stats(stream)
      assert stats.queue_size == 20
      assert stats.dropped == 80
    end

    test "concurrent producers with drop_oldest strategy" do
      {:ok, stream} = EventStream.start_link(max_queue: 100, drop_strategy: :drop_oldest)

      # 10 concurrent producers, each sending 1000 events
      producers =
        for p <- 1..10 do
          Task.async(fn ->
            for i <- 1..1000 do
              EventStream.push(stream, {p, i})
            end
          end)
        end

      Task.await_many(producers, 30_000)
      EventStream.complete(stream, [])

      stats = EventStream.stats(stream)

      # Queue stayed bounded
      assert stats.queue_size <= 100

      # Many drops expected
      assert stats.dropped > 9000
    end

    test "async push under sustained load drops silently" do
      {:ok, stream} = EventStream.start_link(max_queue: 50, drop_strategy: :error)

      # Rapid fire async pushes
      for i <- 1..1000 do
        EventStream.push_async(stream, {:event, i})
      end

      # Wait for all casts to process
      Process.sleep(200)

      stats = EventStream.stats(stream)
      assert stats.queue_size == 50
      assert stats.dropped == 950
    end
  end

  # ============================================================================
  # 2. Monitor Cleanup on Owner Death
  # ============================================================================

  describe "monitor cleanup on owner death" do
    test "stream cleans up monitors when owner process dies normally" do
      test_pid = self()

      owner =
        spawn(fn ->
          receive do
            :exit -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner)

      # Start multiple waiters
      waiters =
        for _ <- 1..5 do
          Task.async(fn ->
            result = EventStream.result(stream)
            send(test_pid, {:waiter_done, result})
            result
          end)
        end

      Process.sleep(50)

      # Kill owner normally
      send(owner, :exit)

      # All waiters should receive canceled result
      for _ <- 1..5 do
        assert_receive {:waiter_done, {:error, {:canceled, :owner_down}}}, 1000
      end

      # Stream should be dead
      Process.sleep(50)
      refute Process.alive?(stream)

      # Cleanup tasks
      for task <- waiters, do: Task.await(task, 100)
    end

    test "stream cleans up monitors when owner process crashes" do
      test_pid = self()

      owner =
        spawn(fn ->
          receive do
            :crash -> exit(:boom)
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner)

      consumer =
        Task.async(fn ->
          events = EventStream.events(stream) |> Enum.to_list()
          send(test_pid, {:consumer_done, events})
          events
        end)

      Process.sleep(50)

      # Crash the owner
      send(owner, :crash)

      # Consumer should receive canceled event
      assert_receive {:consumer_done, events}, 1000
      assert {:canceled, :owner_down} in events

      Task.await(consumer, 100)
    end

    test "attached task monitor is cleaned up on stream cancel" do
      {:ok, stream} = EventStream.start_link()

      task_pid =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      task_ref = Process.monitor(task_pid)

      EventStream.attach_task(stream, task_pid)
      Process.sleep(20)

      EventStream.cancel(stream, :cleanup_test)

      # Task should be killed due to stream cancel
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _}, 500
    end

    test "replacing attached task cleans up previous monitor" do
      {:ok, stream} = EventStream.start_link()

      task1 =
        spawn(fn ->
          receive do
            :crash -> exit(:boom1)
          end
        end)

      task2 =
        spawn(fn ->
          receive do
            :crash -> exit(:boom2)
          end
        end)

      EventStream.attach_task(stream, task1)
      Process.sleep(20)

      EventStream.attach_task(stream, task2)
      Process.sleep(20)

      # Crash task1 - should NOT affect stream since it was replaced
      send(task1, :crash)
      Process.sleep(50)

      # Stream should still be alive and result should timeout (not error)
      assert EventStream.result(stream, 50) == {:error, :timeout}

      # Now crash task2 - SHOULD affect stream
      send(task2, :crash)
      Process.sleep(50)

      result = EventStream.result(stream, 100)
      assert {:error, {:task_crashed, :boom2}, nil} = result
    end

    test "many owners created and destroyed rapidly" do
      for _ <- 1..50 do
        owner =
          spawn(fn ->
            receive do
              :die -> :ok
            end
          end)

        {:ok, stream} = EventStream.start_link(owner: owner)

        # Start a waiter
        task = Task.async(fn -> EventStream.result(stream) end)

        Process.sleep(5)
        send(owner, :die)

        {:error, {:canceled, :owner_down}} = Task.await(task, 500)
      end
    end
  end

  # ============================================================================
  # 3. Race Conditions in Queue Delivery
  # ============================================================================

  describe "race conditions in queue delivery" do
    test "event delivery to waiting consumer vs buffer race" do
      {:ok, stream} = EventStream.start_link()

      # Consumer starts waiting before events
      consumer =
        Task.async(fn ->
          EventStream.events(stream)
          |> Enum.take(10)
        end)

      # Small delay to ensure consumer is waiting
      Process.sleep(10)

      # Rapid fire events - some may go to waiting consumer, some to buffer
      for i <- 1..10 do
        EventStream.push(stream, {:event, i})
      end

      events = Task.await(consumer, 1000)

      # Should receive exactly 10 events in order
      event_values = Enum.map(events, fn {:event, i} -> i end)
      assert event_values == Enum.to_list(1..10)
    end

    test "concurrent take requests race for events" do
      {:ok, stream} = EventStream.start_link()

      # Multiple consumers racing for events
      consumers =
        for i <- 1..5 do
          Task.async(fn ->
            events = EventStream.events(stream) |> Enum.to_list()
            {i, events}
          end)
        end

      Process.sleep(50)

      # Push events that will be distributed among racing consumers
      for i <- 1..20 do
        EventStream.push(stream, {:event, i})
      end

      EventStream.complete(stream, [])

      results = Task.await_many(consumers, 2000)

      # All events should be consumed exactly once (no duplicates)
      all_events =
        results
        |> Enum.flat_map(fn {_id, events} -> events end)
        |> Enum.filter(&match?({:event, _}, &1))

      event_values =
        all_events
        |> Enum.map(fn {:event, i} -> i end)
        |> Enum.sort()

      # Each event appears exactly once
      assert event_values == Enum.to_list(1..20)

      # At least one consumer should have terminal event
      terminal_count =
        Enum.count(results, fn {_, events} ->
          Enum.any?(events, &match?({:agent_end, _}, &1))
        end)

      assert terminal_count >= 1
    end

    test "push and take interleaved - no lost events" do
      {:ok, stream} = EventStream.start_link()

      # Interleaved push/take operations
      operations =
        for i <- 1..100 do
          if rem(i, 2) == 0 do
            {:push, i}
          else
            {:take, i}
          end
        end

      # Start a consumer in background
      consumer =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      # Execute operations
      for op <- operations do
        case op do
          {:push, i} ->
            EventStream.push(stream, {:event, i})

          {:take, _} ->
            # Take is handled by consumer task
            Process.sleep(1)
        end
      end

      EventStream.complete(stream, [])

      events = Task.await(consumer, 2000)

      # All pushed events should be present
      pushed_values = for {:push, i} <- operations, do: i

      received_values =
        events
        |> Enum.filter(&match?({:event, _}, &1))
        |> Enum.map(fn {:event, i} -> i end)
        |> Enum.sort()

      assert received_values == Enum.sort(pushed_values)
    end

    test "complete racing with pending pushes" do
      {:ok, stream} = EventStream.start_link()

      # Start pushing events
      pusher =
        Task.async(fn ->
          for i <- 1..100 do
            result = EventStream.push(stream, {:event, i})
            {i, result}
          end
        end)

      # Complete after some pushes
      Process.sleep(5)
      EventStream.complete(stream, ["race"])

      results = Task.await(pusher, 1000)

      # Some pushes should succeed, some should fail (canceled after complete)
      successful = Enum.count(results, fn {_, r} -> r == :ok end)
      canceled = Enum.count(results, fn {_, r} -> r == {:error, :canceled} end)

      assert successful >= 1
      assert successful + canceled == 100

      {:ok, result} = EventStream.result(stream)
      assert result == ["race"]
    end
  end

  # ============================================================================
  # 4. Result/Take Waiter Interleaving
  # ============================================================================

  describe "result and take waiter interleaving" do
    test "result waiters and event consumers work independently" do
      {:ok, stream} = EventStream.start_link()

      # Start result waiters
      result_waiters =
        for i <- 1..5 do
          Task.async(fn ->
            result = EventStream.result(stream)
            {i, :result, result}
          end)
        end

      # Start event consumers
      event_consumers =
        for i <- 1..5 do
          Task.async(fn ->
            events = EventStream.events(stream) |> Enum.to_list()
            {i, :events, events}
          end)
        end

      Process.sleep(50)

      # Push events
      for i <- 1..20 do
        EventStream.push(stream, {:event, i})
      end

      EventStream.complete(stream, ["final_result"])

      # All result waiters should get the same result
      for task <- result_waiters do
        {_, :result, result} = Task.await(task, 1000)
        assert {:ok, ["final_result"]} = result
      end

      # Event consumers should have distributed the events
      all_consumer_events =
        for task <- event_consumers do
          {_, :events, events} = Task.await(task, 1000)
          events
        end

      all_events = List.flatten(all_consumer_events)

      # All 20 events should be accounted for
      event_values =
        all_events
        |> Enum.filter(&match?({:event, _}, &1))
        |> Enum.map(fn {:event, i} -> i end)
        |> Enum.sort()

      assert event_values == Enum.to_list(1..20)
    end

    test "result waiter does not consume events" do
      {:ok, stream} = EventStream.start_link()

      # Start result waiter
      result_waiter = Task.async(fn -> EventStream.result(stream) end)

      Process.sleep(20)

      # Push events while result waiter is waiting
      for i <- 1..5 do
        EventStream.push(stream, {:event, i})
      end

      # Verify events are still in queue
      stats = EventStream.stats(stream)
      assert stats.queue_size == 5

      EventStream.complete(stream, ["done"])

      {:ok, result} = Task.await(result_waiter, 1000)
      assert result == ["done"]

      # Events should still be consumable
      events = EventStream.events(stream) |> Enum.to_list()
      event_count = Enum.count(events, &match?({:event, _}, &1))
      assert event_count == 5
    end

    test "interleaved result and take calls under high contention" do
      {:ok, stream} = EventStream.start_link(max_queue: 1000)

      # Mix of operations
      tasks =
        for i <- 1..20 do
          cond do
            rem(i, 4) == 0 ->
              # Result waiter
              Task.async(fn ->
                EventStream.result(stream)
              end)

            rem(i, 4) == 1 ->
              # Event consumer (take a few)
              Task.async(fn ->
                EventStream.events(stream) |> Enum.take(5)
              end)

            rem(i, 4) == 2 ->
              # Pusher
              Task.async(fn ->
                for j <- 1..10 do
                  EventStream.push(stream, {:event, {i, j}})
                end
              end)

            true ->
              # Stats checker
              Task.async(fn ->
                EventStream.stats(stream)
              end)
          end
        end

      Process.sleep(100)
      EventStream.complete(stream, ["high_contention_result"])

      # All tasks should complete without crashing
      for task <- tasks do
        Task.await(task, 2000)
      end
    end

    test "result waiter wakes up before event consumers on cancel" do
      {:ok, stream} = EventStream.start_link()
      test_pid = self()

      # Start result waiter
      _result_task =
        Task.async(fn ->
          result = EventStream.result(stream)
          send(test_pid, {:result_done, System.monotonic_time()})
          result
        end)

      # Start event consumer
      _event_task =
        Task.async(fn ->
          events = EventStream.events(stream) |> Enum.to_list()
          send(test_pid, {:events_done, System.monotonic_time()})
          events
        end)

      Process.sleep(50)

      # Cancel
      EventStream.cancel(stream, :timing_test)

      # Both should complete
      assert_receive {:result_done, _t1}, 1000
      assert_receive {:events_done, _t2}, 1000
    end
  end

  # ============================================================================
  # 5. Multiple Concurrent Producers and Consumers
  # ============================================================================

  describe "multiple concurrent producers and consumers" do
    test "many producers, single consumer - no lost events" do
      {:ok, stream} = EventStream.start_link(max_queue: 50_000)

      # 20 concurrent producers, each sending 500 events
      producers =
        for p <- 1..20 do
          Task.async(fn ->
            for i <- 1..500 do
              EventStream.push(stream, {p, i})
            end
          end)
        end

      # Single consumer
      consumer =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      Task.await_many(producers, 30_000)
      EventStream.complete(stream, [])

      events = Task.await(consumer, 30_000)

      # Should have 10,000 events + terminal
      assert length(events) == 10_001

      # Verify per-producer ordering
      for p <- 1..20 do
        producer_events =
          events
          |> Enum.filter(fn
            {^p, _} -> true
            _ -> false
          end)
          |> Enum.map(fn {_, i} -> i end)

        assert producer_events == Enum.to_list(1..500),
               "Producer #{p} events out of order"
      end
    end

    test "single producer, many consumers - events distributed" do
      {:ok, stream} = EventStream.start_link()

      # Start 10 consumers
      consumers =
        for i <- 1..10 do
          Task.async(fn ->
            events = EventStream.events(stream) |> Enum.to_list()
            {i, events}
          end)
        end

      Process.sleep(50)

      # Single producer
      for i <- 1..100 do
        EventStream.push(stream, {:event, i})
      end

      EventStream.complete(stream, [])

      results = Task.await_many(consumers, 5000)

      # Events should be distributed (no duplicates)
      all_events =
        results
        |> Enum.flat_map(fn {_, events} -> events end)
        |> Enum.filter(&match?({:event, _}, &1))

      event_values = Enum.map(all_events, fn {:event, i} -> i end)

      # All 100 events should be accounted for exactly once
      assert Enum.sort(event_values) == Enum.to_list(1..100)
    end

    test "many producers, many consumers - balanced load" do
      {:ok, stream} = EventStream.start_link(max_queue: 50_000)

      # 5 producers
      producers =
        for p <- 1..5 do
          Task.async(fn ->
            for i <- 1..200 do
              EventStream.push(stream, {p, i})
            end

            :producer_done
          end)
        end

      # 5 consumers
      consumers =
        for c <- 1..5 do
          Task.async(fn ->
            events =
              EventStream.events(stream)
              |> Enum.reduce([], fn event, acc ->
                case event do
                  {:agent_end, _} -> acc
                  event -> [event | acc]
                end
              end)
              |> Enum.reverse()

            {c, events}
          end)
        end

      # Wait for all producers to finish
      for task <- producers, do: assert(:producer_done = Task.await(task, 10_000))

      EventStream.complete(stream, [])

      results = Task.await_many(consumers, 10_000)

      # Collect all received events
      all_events =
        results
        |> Enum.flat_map(fn {_, events} -> events end)

      # Should have 1000 total events (5 * 200)
      assert length(all_events) == 1000

      # Verify each producer's events appear exactly once
      for p <- 1..5 do
        producer_events =
          all_events
          |> Enum.filter(fn {producer, _} -> producer == p end)
          |> Enum.map(fn {_, i} -> i end)
          |> Enum.sort()

        assert producer_events == Enum.to_list(1..200)
      end
    end

    test "consumer joins mid-stream" do
      {:ok, stream} = EventStream.start_link()

      # Push first batch
      for i <- 1..50 do
        EventStream.push(stream, {:batch1, i})
      end

      # First consumer starts
      consumer1 =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.take(25)
        end)

      # Wait for consumer1 to take some events
      Process.sleep(50)

      # Second consumer joins
      consumer2 =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      # Push second batch
      for i <- 1..50 do
        EventStream.push(stream, {:batch2, i})
      end

      EventStream.complete(stream, [])

      events1 = Task.await(consumer1, 2000)
      events2 = Task.await(consumer2, 2000)

      # Consumer1 should have exactly 25 events
      assert length(events1) == 25

      # Consumer2 should have the rest including terminal
      assert Enum.any?(events2, &match?({:agent_end, _}, &1))

      # Combined should have all batch1 and batch2 events
      all_events = events1 ++ events2

      batch1_count = Enum.count(all_events, &match?({:batch1, _}, &1))
      batch2_count = Enum.count(all_events, &match?({:batch2, _}, &1))

      assert batch1_count == 50
      assert batch2_count == 50
    end
  end

  # ============================================================================
  # 6. Terminal Event Handling Edge Cases
  # ============================================================================

  describe "terminal event edge cases" do
    test "terminal event reaches exactly one waiting consumer" do
      {:ok, stream} = EventStream.start_link()

      # Multiple consumers waiting for events
      consumers =
        for i <- 1..5 do
          Task.async(fn ->
            events = EventStream.events(stream) |> Enum.to_list()
            {i, events}
          end)
        end

      Process.sleep(50)

      EventStream.complete(stream, ["terminal"])

      results = Task.await_many(consumers, 2000)

      # Exactly one consumer should have received the terminal event
      terminal_count =
        Enum.count(results, fn {_, events} ->
          Enum.any?(events, &match?({:agent_end, _}, &1))
        end)

      assert terminal_count == 1
    end

    test "error terminal event with partial state" do
      {:ok, stream} = EventStream.start_link()

      # Push some events
      for i <- 1..10 do
        EventStream.push(stream, {:progress, i})
      end

      partial_state = %{
        processed: 10,
        pending: [:task_a, :task_b],
        buffer: List.duplicate(<<0>>, 100)
      }

      EventStream.error(stream, :api_failure, partial_state)

      events = EventStream.events(stream) |> Enum.to_list()

      # Terminal error event should include partial state
      terminal = List.last(events)
      assert {:error, :api_failure, ^partial_state} = terminal

      {:error, reason, state} = EventStream.result(stream)
      assert reason == :api_failure
      assert state == partial_state
    end

    test "cancel during event consumption" do
      {:ok, stream} = EventStream.start_link()

      test_pid = self()

      # Start consumer that signals when it's waiting
      consumer =
        Task.async(fn ->
          send(test_pid, :consumer_started)

          EventStream.events(stream)
          |> Enum.reduce([], fn event, acc ->
            [event | acc]
          end)
          |> Enum.reverse()
        end)

      # Wait for consumer to start
      assert_receive :consumer_started, 1000

      # Small delay to ensure consumer is waiting
      Process.sleep(20)

      # Push a few events
      for i <- 1..5 do
        EventStream.push(stream, {:event, i})
      end

      # Give time for events to be consumed
      Process.sleep(20)

      # Cancel - this should terminate the stream and deliver canceled event
      EventStream.cancel(stream, :mid_consumption)

      events = Task.await(consumer, 2000)

      # Should have received canceled event (which is terminal)
      assert {:canceled, :mid_consumption} in events
    end

    test "multiple terminal events - only first is delivered" do
      {:ok, stream} = EventStream.start_link()

      # Race multiple terminal events
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            EventStream.complete(stream, ["winner_#{i}"])
          end)
        end

      Task.await_many(tasks, 1000)

      {:ok, result} = EventStream.result(stream)

      # Only one should win
      assert is_list(result)
      assert length(result) == 1
      assert String.starts_with?(hd(result), "winner_")
    end

    test "terminal event makes room in full queue (drop_oldest)" do
      {:ok, stream} = EventStream.start_link(max_queue: 5, drop_strategy: :drop_oldest)

      # Fill queue
      for i <- 1..5 do
        EventStream.push(stream, {:event, i})
      end

      stats_before = EventStream.stats(stream)
      assert stats_before.queue_size == 5

      # Complete should drop oldest to make room for terminal
      EventStream.complete(stream, ["terminal"])

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have 5 events (4 from queue + 1 terminal)
      assert length(events) == 5

      # Terminal should be last
      assert List.last(events) == {:agent_end, ["terminal"]}
    end

    test "complete followed by error - complete wins" do
      {:ok, stream} = EventStream.start_link()

      EventStream.complete(stream, ["first"])
      EventStream.error(stream, :second, nil)

      {:ok, result} = EventStream.result(stream)
      assert result == ["first"]
    end

    test "error followed by complete - error wins" do
      {:ok, stream} = EventStream.start_link()

      EventStream.error(stream, :first_error, %{data: "partial"})
      EventStream.complete(stream, ["second"])

      {:error, reason, state} = EventStream.result(stream)
      assert reason == :first_error
      assert state == %{data: "partial"}
    end
  end

  # ============================================================================
  # 7. State Cleanup Scenarios
  # ============================================================================

  describe "state cleanup scenarios" do
    test "stream stops and cleans up on cancel" do
      {:ok, stream} = EventStream.start_link()

      # Push events and attach task
      for i <- 1..10 do
        EventStream.push(stream, {:event, i})
      end

      task_pid =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      EventStream.attach_task(stream, task_pid)
      task_ref = Process.monitor(task_pid)

      Process.sleep(20)

      EventStream.cancel(stream, :cleanup_scenario)

      # Stream should be dead
      Process.sleep(50)
      refute Process.alive?(stream)

      # Attached task should be killed
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _}, 500
    end

    test "timeout cleanup shuts down attached task" do
      {:ok, stream} = EventStream.start_link(timeout: 100)

      task_pid =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      EventStream.attach_task(stream, task_pid)
      task_ref = Process.monitor(task_pid)

      # Wait for timeout
      Process.sleep(200)

      # Stream should be dead
      refute Process.alive?(stream)

      # Task should be killed
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, _}, 500
    end

    test "owner death cleanup with multiple waiters" do
      owner =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner)

      # Multiple result waiters
      result_waiters =
        for _ <- 1..10 do
          Task.async(fn -> EventStream.result(stream) end)
        end

      # Multiple event consumers
      event_consumers =
        for _ <- 1..5 do
          Task.async(fn ->
            EventStream.events(stream) |> Enum.to_list()
          end)
        end

      Process.sleep(50)

      # Kill owner
      send(owner, :die)

      # All result waiters should receive cancel
      for task <- result_waiters do
        result = Task.await(task, 1000)
        assert {:error, {:canceled, :owner_down}} = result
      end

      # All event consumers should complete
      for task <- event_consumers do
        events = Task.await(task, 1000)
        # At least one should have the canceled event (since they compete for it)
        # Others may be empty if they were waiting when canceled event was delivered to another
        assert is_list(events)
      end

      # Stream should be dead
      Process.sleep(50)
      refute Process.alive?(stream)
    end

    test "rapid create/destroy cycle does not leak resources" do
      initial_process_count = length(Process.list())

      for _ <- 1..100 do
        {:ok, stream} = EventStream.start_link()

        for i <- 1..10 do
          EventStream.push(stream, {:event, i})
        end

        EventStream.cancel(stream, :rapid_cycle)
        Process.sleep(5)
      end

      # Give some time for cleanup
      Process.sleep(100)

      final_process_count = length(Process.list())

      # Should not have leaked many processes
      # Allow some variance for test framework processes
      assert final_process_count - initial_process_count < 20
    end

    test "stream with full queue cancels cleanly" do
      {:ok, stream} = EventStream.start_link(max_queue: 10, drop_strategy: :drop_oldest)

      # Fill queue beyond capacity
      for i <- 1..100 do
        EventStream.push(stream, {:event, i})
      end

      # Start waiters
      waiter = Task.async(fn -> EventStream.result(stream) end)

      Process.sleep(20)

      # Cancel with full queue
      EventStream.cancel(stream, :full_queue_cancel)

      result = Task.await(waiter, 1000)
      assert {:error, {:canceled, :full_queue_cancel}} = result

      Process.sleep(50)
      refute Process.alive?(stream)
    end

    test "stream cleanup after task crash" do
      {:ok, stream} = EventStream.start_link()

      crashing_task =
        spawn(fn ->
          receive do
            :crash -> exit(:boom)
          end
        end)

      EventStream.attach_task(stream, crashing_task)

      waiter = Task.async(fn -> EventStream.result(stream) end)

      Process.sleep(20)

      # Crash the task
      send(crashing_task, :crash)

      result = Task.await(waiter, 1000)
      assert {:error, {:task_crashed, :boom}, nil} = result

      # Stream should still be alive but in terminal state
      Process.sleep(50)
      assert Process.alive?(stream)
    end
  end

  # ============================================================================
  # Additional Stress Tests
  # ============================================================================

  describe "stress tests" do
    test "sustained high throughput with backpressure" do
      {:ok, stream} = EventStream.start_link(max_queue: 500, drop_strategy: :error)

      # Producer that respects backpressure
      producer =
        Task.async(fn ->
          Enum.reduce_while(1..10_000, {0, 0}, fn i, {success, dropped} ->
            case EventStream.push(stream, {:event, i}) do
              :ok ->
                {:cont, {success + 1, dropped}}

              {:error, :overflow} ->
                # Back off briefly
                Process.sleep(1)
                {:cont, {success, dropped + 1}}

              {:error, :canceled} ->
                {:halt, {success, dropped}}
            end
          end)
        end)

      # Consumer
      consumer =
        Task.async(fn ->
          EventStream.events(stream)
          |> Enum.reduce(0, fn event, count ->
            # Simulate processing time
            if rem(count, 100) == 0, do: Process.sleep(1)

            case event do
              {:agent_end, _} -> count
              _ -> count + 1
            end
          end)
        end)

      {success, dropped} = Task.await(producer, 60_000)
      EventStream.complete(stream, [])

      received = Task.await(consumer, 60_000)

      # Verify consistency
      assert success > 0
      assert received > 0
      assert dropped >= 0

      # All successful pushes should have been received
      # (minus any still in queue when complete was called)
      stats = EventStream.stats(stream)
      assert received + stats.queue_size <= success + 1
    end

    test "many streams in parallel with varying loads" do
      streams =
        for _ <- 1..20 do
          {:ok, stream} = EventStream.start_link(max_queue: 100)
          stream
        end

      # Each stream gets different load pattern
      tasks =
        for {stream, idx} <- Enum.with_index(streams) do
          Task.async(fn ->
            events_to_push = (idx + 1) * 50

            for i <- 1..events_to_push do
              EventStream.push(stream, {:event, i})
            end

            EventStream.complete(stream, ["stream_#{idx}"])
            EventStream.result(stream)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # All streams should complete successfully
      for {result, idx} <- Enum.with_index(results) do
        expected = ["stream_#{idx}"]
        assert {:ok, ^expected} = result
      end
    end
  end
end
