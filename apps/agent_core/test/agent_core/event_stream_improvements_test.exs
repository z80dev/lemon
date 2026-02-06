defmodule AgentCore.EventStreamImprovementsTest do
  @moduledoc """
  Additional tests for EventStream edge cases and robustness including:
  - Error recovery scenarios
  - Memory management edge cases
  - Race conditions
  - Telemetry events
  """
  use ExUnit.Case, async: true

  alias AgentCore.EventStream

  # ============================================================================
  # Extended Stats
  # ============================================================================

  describe "stats edge cases" do
    test "stats returns correct values for empty stream" do
      {:ok, stream} = EventStream.start_link()

      stats = EventStream.stats(stream)
      assert stats.queue_size == 0
      assert stats.max_queue == 10_000
      assert stats.dropped == 0
    end

    test "stats updates correctly during push/pull cycle" do
      {:ok, stream} = EventStream.start_link()

      # Push events
      for i <- 1..5 do
        EventStream.push(stream, {:event, i})
      end

      assert EventStream.stats(stream).queue_size == 5

      # Pull some events
      EventStream.events(stream) |> Enum.take(3)

      assert EventStream.stats(stream).queue_size == 2
    end

    test "stats tracks drops accurately with drop_oldest" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :drop_oldest)

      for i <- 1..10 do
        EventStream.push(stream, {:event, i})
      end

      stats = EventStream.stats(stream)
      assert stats.dropped == 7
      assert stats.queue_size == 3
    end
  end

  # ============================================================================
  # Error Recovery
  # ============================================================================

  describe "error recovery" do
    test "stream handles multiple terminal events gracefully" do
      {:ok, stream} = EventStream.start_link()

      EventStream.push(stream, {:event, 1})
      EventStream.complete(stream, ["first"])

      # These should be no-ops after completion
      EventStream.complete(stream, ["second"])
      EventStream.error(stream, :late_error, nil)

      {:ok, result} = EventStream.result(stream)
      assert result == ["first"]
    end

    test "stream handles error followed by complete" do
      {:ok, stream} = EventStream.start_link()

      EventStream.error(stream, :first_error, nil)
      EventStream.complete(stream, ["should_be_ignored"])

      {:error, reason, _} = EventStream.result(stream)
      assert reason == :first_error
    end

    test "pushing to canceled stream returns error" do
      {:ok, stream} = EventStream.start_link()

      task =
        Task.async(fn ->
          Process.sleep(50)
          EventStream.push(stream, {:late_event, 1})
        end)

      EventStream.cancel(stream, :early_cancel)

      result = Task.await(task, 1000)
      assert result == {:error, :canceled}
    end

    test "result returns stream_not_found for dead stream" do
      {:ok, stream} = EventStream.start_link()
      GenServer.stop(stream)
      Process.sleep(20)

      assert EventStream.result(stream, 100) == {:error, :stream_not_found}
    end

    test "push returns canceled for dead stream" do
      {:ok, stream} = EventStream.start_link()
      GenServer.stop(stream)
      Process.sleep(20)

      assert EventStream.push(stream, {:event, 1}) == {:error, :canceled}
    end
  end

  # ============================================================================
  # Memory Management Edge Cases
  # ============================================================================

  describe "memory management" do
    test "stream handles rapid push/take cycles" do
      {:ok, stream} = EventStream.start_link()

      # Rapid push and take in parallel
      pusher =
        Task.async(fn ->
          for i <- 1..100 do
            EventStream.push(stream, {:event, i})
          end
        end)

      puller =
        Task.async(fn ->
          stream
          |> EventStream.events()
          |> Enum.take_while(fn e -> not match?({:agent_end, _}, e) end)
          |> length()
        end)

      Task.await(pusher, 1000)
      EventStream.complete(stream, [])

      count = Task.await(puller, 1000)
      assert count == 100
    end

    test "large number of waiters all get notified on complete" do
      {:ok, stream} = EventStream.start_link()

      # Start multiple result waiters
      tasks =
        for _ <- 1..10 do
          Task.async(fn -> EventStream.result(stream) end)
        end

      Process.sleep(50)
      EventStream.complete(stream, ["done"])

      for task <- tasks do
        {:ok, result} = Task.await(task, 1000)
        assert result == ["done"]
      end
    end

    test "large number of event waiters work correctly" do
      {:ok, stream} = EventStream.start_link()

      # Start event consumers
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            stream
            |> EventStream.events()
            |> Enum.to_list()
          end)
        end

      Process.sleep(50)

      # Push enough events for all consumers
      for i <- 1..20 do
        EventStream.push(stream, {:event, i})
      end

      EventStream.complete(stream, [])

      # All tasks should complete
      results =
        for task <- tasks do
          Task.await(task, 1000)
        end

      # Combined results should include all events (distributed among consumers)
      all_events = List.flatten(results)
      # At minimum, terminal event should be received by at least one consumer
      assert Enum.any?(all_events, fn e -> match?({:agent_end, _}, e) end)
    end
  end

  # ============================================================================
  # Concurrent Operations
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent pushers work correctly" do
      {:ok, stream} = EventStream.start_link(max_queue: 1000)

      # Start multiple pushers
      pusher_tasks =
        for i <- 1..5 do
          Task.async(fn ->
            for j <- 1..50 do
              EventStream.push(stream, {:event, {i, j}})
            end
          end)
        end

      # Wait for all pushers
      for task <- pusher_tasks do
        Task.await(task, 5000)
      end

      EventStream.complete(stream, [])

      # Should have all 250 events plus agent_end
      events = EventStream.events(stream) |> Enum.to_list()
      assert length(events) == 251
    end

    test "result and events consumers interleave correctly" do
      {:ok, stream} = EventStream.start_link()

      # Mix of result waiters and event consumers
      result_tasks =
        for _ <- 1..3 do
          Task.async(fn -> EventStream.result(stream) end)
        end

      event_tasks =
        for _ <- 1..3 do
          Task.async(fn ->
            EventStream.events(stream) |> Enum.to_list()
          end)
        end

      Process.sleep(50)

      # Push some events
      for i <- 1..10 do
        EventStream.push(stream, {:event, i})
      end

      EventStream.complete(stream, ["final"])

      # All result waiters should get the same result
      for task <- result_tasks do
        {:ok, result} = Task.await(task, 1000)
        assert result == ["final"]
      end

      # All event consumers should complete
      # Note: events are distributed among consumers, so terminal event goes to one
      all_events = for task <- event_tasks, do: Task.await(task, 1000)
      combined = List.flatten(all_events)
      assert Enum.any?(combined, fn e -> match?({:agent_end, _}, e) end)
    end
  end

  # ============================================================================
  # Stress Tests
  # ============================================================================

  describe "stress tests" do
    test "handles many rapid pushes without losing events" do
      {:ok, stream} = EventStream.start_link(max_queue: 10_000)

      # Push many events rapidly
      for i <- 1..1000 do
        EventStream.push(stream, {:event, i})
      end

      EventStream.complete(stream, [])

      events = EventStream.events(stream) |> Enum.to_list()
      # 1000 events + agent_end
      assert length(events) == 1001
    end

    test "handles many async pushes" do
      {:ok, stream} = EventStream.start_link(max_queue: 10_000)

      # Push many events asynchronously
      for i <- 1..500 do
        EventStream.push_async(stream, {:event, i})
      end

      # Wait for async pushes to process
      Process.sleep(100)

      EventStream.complete(stream, [])

      # Wait a bit more
      Process.sleep(50)

      events = EventStream.events(stream) |> Enum.to_list()
      # Should have 500 events + agent_end
      assert length(events) == 501
    end
  end

  # ============================================================================
  # Options Validation
  # ============================================================================

  describe "options" do
    test "all options can be specified together" do
      {:ok, stream} =
        EventStream.start_link(
          owner: self(),
          max_queue: 100,
          drop_strategy: :drop_oldest,
          timeout: 60_000
        )

      assert Process.alive?(stream)

      stats = EventStream.stats(stream)
      assert stats.max_queue == 100
    end

    test "default values are used when options not specified" do
      {:ok, stream} = EventStream.start_link()

      stats = EventStream.stats(stream)
      assert stats.max_queue == 10_000
    end

    test "infinity timeout works" do
      {:ok, stream} = EventStream.start_link(timeout: :infinity)

      # Stream should stay alive indefinitely
      Process.sleep(100)
      assert Process.alive?(stream)

      EventStream.complete(stream, [])
      {:ok, result} = EventStream.result(stream)
      assert result == []
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "attached tasks" do
    test "re-attaching task replaces the old monitor (old task crash does not terminate stream)" do
      {:ok, stream} = EventStream.start_link()

      task1 =
        spawn(fn ->
          receive do
            :crash -> exit(:task1_boom)
          end
        end)

      task2 =
        spawn(fn ->
          receive do
            :crash -> exit(:task2_boom)
          end
        end)

      :ok = EventStream.attach_task(stream, task1)
      :ok = EventStream.attach_task(stream, task2)

      # Crash the *old* task. Stream should ignore it and keep running.
      send(task1, :crash)
      Process.sleep(20)

      # Ensure we didn't transition to a terminal error.
      assert EventStream.result(stream, 10) == {:error, :timeout}

      EventStream.complete(stream, ["ok"])
      assert {:ok, ["ok"]} = EventStream.result(stream, 1000)

      # Cleanup
      if Process.alive?(task2), do: send(task2, :crash)
    end
  end

  describe "edge cases" do
    test "empty stream with immediate complete" do
      {:ok, stream} = EventStream.start_link()

      EventStream.complete(stream, [])

      events = EventStream.events(stream) |> Enum.to_list()
      assert events == [{:agent_end, []}]

      {:ok, result} = EventStream.result(stream)
      assert result == []
    end

    test "push_async to dead stream does not crash" do
      {:ok, stream} = EventStream.start_link()
      GenServer.stop(stream)
      Process.sleep(20)

      # Should not raise
      assert :ok = EventStream.push_async(stream, {:event, 1})
    end

    test "attach_task to dead stream does not crash" do
      {:ok, stream} = EventStream.start_link()
      GenServer.stop(stream)
      Process.sleep(20)

      # Should not raise
      assert :ok = EventStream.attach_task(stream, self())
    end

    test "cancel with default reason" do
      {:ok, stream} = EventStream.start_link()

      EventStream.cancel(stream)

      Process.sleep(20)
      refute Process.alive?(stream)
    end
  end
end
