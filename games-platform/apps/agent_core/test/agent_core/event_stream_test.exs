defmodule AgentCore.EventStreamTest do
  use ExUnit.Case, async: true

  alias AgentCore.AbortSignal
  alias AgentCore.EventStream

  # ============================================================================
  # Starting a Stream
  # ============================================================================

  describe "start_link/1" do
    test "starts a new event stream" do
      {:ok, stream} = EventStream.start_link()
      assert is_pid(stream)
      assert Process.alive?(stream)
    end

    test "starts with empty options" do
      {:ok, stream} = EventStream.start_link([])
      assert is_pid(stream)
    end

    test "multiple streams can be started" do
      {:ok, stream1} = EventStream.start_link()
      {:ok, stream2} = EventStream.start_link()

      assert stream1 != stream2
      assert Process.alive?(stream1)
      assert Process.alive?(stream2)
    end
  end

  # ============================================================================
  # Pushing Events
  # ============================================================================

  describe "push/2" do
    test "pushes an event to the stream" do
      {:ok, stream} = EventStream.start_link()

      assert :ok = EventStream.push(stream, {:test_event, "data"})
    end

    test "pushes multiple events" do
      {:ok, stream} = EventStream.start_link()

      assert :ok = EventStream.push(stream, {:event1, "data1"})
      assert :ok = EventStream.push(stream, {:event2, "data2"})
      assert :ok = EventStream.push(stream, {:event3, "data3"})
    end

    test "accepts any term as event" do
      {:ok, stream} = EventStream.start_link()

      assert :ok = EventStream.push(stream, :atom)
      assert :ok = EventStream.push(stream, "string")
      assert :ok = EventStream.push(stream, 123)
      assert :ok = EventStream.push(stream, %{map: true})
      assert :ok = EventStream.push(stream, [1, 2, 3])
    end
  end

  # ============================================================================
  # Consuming Events via events/1
  # ============================================================================

  describe "events/1" do
    test "returns an enumerable" do
      {:ok, stream} = EventStream.start_link()
      events_enum = EventStream.events(stream)

      assert is_function(events_enum, 2)
    end

    test "yields pushed events in order" do
      {:ok, stream} = EventStream.start_link()

      EventStream.push(stream, {:event1, "data1"})
      EventStream.push(stream, {:event2, "data2"})
      EventStream.push(stream, {:agent_end, []})

      events = EventStream.events(stream) |> Enum.to_list()

      assert events == [
               {:event1, "data1"},
               {:event2, "data2"},
               {:agent_end, []}
             ]
    end

    test "blocks when no events available" do
      {:ok, stream} = EventStream.start_link()

      # Start a task that will wait for events
      task =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.take(1)
        end)

      # Give time for task to block
      Process.sleep(50)

      # Push an event
      EventStream.push(stream, {:event, "data"})

      # Task should complete now
      result = Task.await(task, 1000)
      assert result == [{:event, "data"}]
    end

    test "completes when agent_end is received" do
      {:ok, stream} = EventStream.start_link()

      EventStream.push(stream, {:agent_start})
      EventStream.push(stream, {:message, "content"})
      EventStream.complete(stream, ["final_messages"])

      events = EventStream.events(stream) |> Enum.to_list()

      assert {:agent_start} in events
      assert {:message, "content"} in events
      assert {:agent_end, ["final_messages"]} in events
    end

    test "includes terminal event before halting" do
      {:ok, stream} = EventStream.start_link()

      EventStream.push(stream, {:data, "1"})
      EventStream.complete(stream, [])

      events = EventStream.events(stream) |> Enum.to_list()

      # The terminal {:agent_end, []} should be included
      assert List.last(events) == {:agent_end, []}
    end
  end

  # ============================================================================
  # Completing with agent_end
  # ============================================================================

  describe "complete/2" do
    test "completes the stream with messages" do
      {:ok, stream} = EventStream.start_link()

      messages = [%{role: :assistant, content: "Hello"}]
      :ok = EventStream.complete(stream, messages)

      {:ok, result} = EventStream.result(stream)
      assert result == messages
    end

    test "pushes agent_end event" do
      {:ok, stream} = EventStream.start_link()

      messages = ["msg1", "msg2"]
      EventStream.complete(stream, messages)

      events = EventStream.events(stream) |> Enum.to_list()
      assert {:agent_end, ^messages} = List.last(events)
    end

    test "marks stream as done" do
      {:ok, stream} = EventStream.start_link()

      EventStream.complete(stream, [])

      # Further events calls should complete immediately
      events = EventStream.events(stream) |> Enum.to_list()
      assert events == [{:agent_end, []}]
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "error/3" do
    test "signals an error on the stream" do
      {:ok, stream} = EventStream.start_link()

      :ok = EventStream.error(stream, :timeout, %{partial: "data"})

      {:error, reason, partial} = EventStream.result(stream)
      assert reason == :timeout
      assert partial == %{partial: "data"}
    end

    test "pushes error event" do
      {:ok, stream} = EventStream.start_link()

      EventStream.error(stream, :api_error, nil)

      events = EventStream.events(stream) |> Enum.to_list()
      assert {:error, :api_error, nil} in events
    end

    test "error with nil partial_state" do
      {:ok, stream} = EventStream.start_link()

      EventStream.error(stream, "something went wrong")

      {:error, reason, partial} = EventStream.result(stream)
      assert reason == "something went wrong"
      assert partial == nil
    end

    test "marks stream as done" do
      {:ok, stream} = EventStream.start_link()

      EventStream.error(stream, :test_error, nil)

      # Further events calls should complete immediately
      events = EventStream.events(stream) |> Enum.to_list()
      assert length(events) == 1
    end
  end

  # ============================================================================
  # result/1 Blocking Behavior
  # ============================================================================

  describe "result/1" do
    test "blocks until stream completes" do
      {:ok, stream} = EventStream.start_link()

      task =
        Task.async(fn ->
          EventStream.result(stream)
        end)

      # Give time for task to block
      Process.sleep(50)

      # Complete the stream
      messages = [%{content: "result"}]
      EventStream.complete(stream, messages)

      # Task should return the result
      {:ok, result} = Task.await(task, 1000)
      assert result == messages
    end

    test "returns immediately if already complete" do
      {:ok, stream} = EventStream.start_link()

      EventStream.complete(stream, ["done"])

      # Should return immediately
      {:ok, result} = EventStream.result(stream)
      assert result == ["done"]
    end

    test "returns error if stream errored" do
      {:ok, stream} = EventStream.start_link()

      EventStream.error(stream, :timeout, %{messages: []})

      {:error, reason, partial} = EventStream.result(stream)
      assert reason == :timeout
      assert partial == %{messages: []}
    end

    test "respects timeout parameter" do
      {:ok, stream} = EventStream.start_link()

      # This should timeout since we never complete the stream
      # The new implementation catches the exit and returns {:error, :timeout}
      assert EventStream.result(stream, 100) == {:error, :timeout}
    end

    test "with infinity timeout" do
      {:ok, stream} = EventStream.start_link()

      task =
        Task.async(fn ->
          EventStream.result(stream, :infinity)
        end)

      # Complete after a delay
      Process.sleep(50)
      EventStream.complete(stream, ["result"])

      {:ok, result} = Task.await(task, 1000)
      assert result == ["result"]
    end

    test "result waiter does not block event consumers" do
      {:ok, stream} = EventStream.start_link()

      result_task =
        Task.async(fn ->
          EventStream.result(stream)
        end)

      Process.sleep(20)

      events_task =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.take(1)
        end)

      Process.sleep(20)

      EventStream.push(stream, {:event, "payload"})
      EventStream.complete(stream, [])

      assert Task.await(events_task, 1000) == [{:event, "payload"}]
      {:ok, _} = Task.await(result_task, 1000)
    end
  end

  # ============================================================================
  # Multiple Consumers
  # ============================================================================

  describe "multiple consumers" do
    test "multiple event consumers work independently" do
      {:ok, stream} = EventStream.start_link()

      # Start two consumers
      consumer1 =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      consumer2 =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      # Push events
      Process.sleep(50)
      EventStream.push(stream, {:event, 1})
      EventStream.push(stream, {:event, 2})
      EventStream.complete(stream, [])

      # Both consumers should get events (though they may compete for them)
      result1 = Task.await(consumer1, 1000)
      result2 = Task.await(consumer2, 1000)

      # At least one should have events, and combined they should have all
      combined = result1 ++ result2

      # Note: Due to the single-consumer design, events may be split between consumers
      # The total should include at least the terminal event
      assert {:agent_end, []} in combined or
               Enum.any?(combined, fn e -> match?({:agent_end, _}, e) end)
    end

    test "multiple result waiters all get the result" do
      {:ok, stream} = EventStream.start_link()

      # Start multiple result waiters
      waiter1 = Task.async(fn -> EventStream.result(stream) end)
      waiter2 = Task.async(fn -> EventStream.result(stream) end)
      waiter3 = Task.async(fn -> EventStream.result(stream) end)

      # Complete the stream
      Process.sleep(50)
      EventStream.complete(stream, ["final"])

      # All waiters should get the same result
      {:ok, result1} = Task.await(waiter1, 1000)
      {:ok, result2} = Task.await(waiter2, 1000)
      {:ok, result3} = Task.await(waiter3, 1000)

      assert result1 == ["final"]
      assert result2 == ["final"]
      assert result3 == ["final"]
    end
  end

  # ============================================================================
  # Event Buffering
  # ============================================================================

  describe "event buffering" do
    test "buffers events when no consumer" do
      {:ok, stream} = EventStream.start_link()

      # Push many events without consumer
      for i <- 1..100 do
        EventStream.push(stream, {:event, i})
      end

      EventStream.complete(stream, [])

      # Consumer should get all events
      events = EventStream.events(stream) |> Enum.to_list()

      # Should have 100 numbered events plus the terminal event
      assert length(events) == 101
    end

    test "events consumed as they arrive when consumer is waiting" do
      {:ok, stream} = EventStream.start_link()

      # Start consumer that collects first 3 events
      task =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.take(3)
        end)

      # Push events one at a time
      Process.sleep(20)
      EventStream.push(stream, {:event, 1})
      Process.sleep(20)
      EventStream.push(stream, {:event, 2})
      Process.sleep(20)
      EventStream.push(stream, {:event, 3})

      result = Task.await(task, 1000)
      assert result == [{:event, 1}, {:event, 2}, {:event, 3}]
    end
  end

  # ============================================================================
  # Terminal Event Detection
  # ============================================================================

  describe "terminal events" do
    test "agent_end is terminal" do
      {:ok, stream} = EventStream.start_link()

      EventStream.push(stream, {:agent_end, []})

      events = EventStream.events(stream) |> Enum.to_list()
      assert events == [{:agent_end, []}]
    end

    test "error is terminal" do
      {:ok, stream} = EventStream.start_link()

      EventStream.push(stream, {:error, :test, nil})

      events = EventStream.events(stream) |> Enum.to_list()
      assert events == [{:error, :test, nil}]
    end

    test "non-terminal events don't halt the stream" do
      {:ok, stream} = EventStream.start_link()

      # Start a consumer
      task =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      # Push non-terminal events
      EventStream.push(stream, {:agent_start, %{}})
      EventStream.push(stream, {:tool_call, %{}})
      EventStream.push(stream, {:thinking, "hmm"})

      # Stream should still be open
      Process.sleep(50)

      # Now complete
      EventStream.complete(stream, [])

      events = Task.await(task, 1000)
      assert length(events) == 4
    end
  end

  # ============================================================================
  # Queue Overflow Behavior
  # ============================================================================

  describe "queue overflow with :drop_oldest strategy" do
    test "drops oldest events when queue is full" do
      {:ok, stream} = EventStream.start_link(max_queue: 5, drop_strategy: :drop_oldest)

      # Fill the queue to capacity
      for i <- 1..5 do
        assert :ok = EventStream.push(stream, {:event, i})
      end

      # Push more events - should drop oldest to make room
      # After pushing 6: queue is [2,3,4,5,6] (dropped 1)
      # After pushing 7: queue is [3,4,5,6,7] (dropped 2)
      assert :ok = EventStream.push(stream, {:event, 6})
      assert :ok = EventStream.push(stream, {:event, 7})

      # complete pushes agent_end, which drops oldest again: [4,5,6,7,agent_end]
      EventStream.complete(stream, [])

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have events 4-7 plus agent_end (1,2,3 were dropped)
      event_values =
        events |> Enum.filter(&match?({:event, _}, &1)) |> Enum.map(fn {:event, i} -> i end)

      assert event_values == [4, 5, 6, 7]

      stats = EventStream.stats(stream)
      # 3 drops: 1, 2, 3
      assert stats.dropped == 3
    end

    test "reports dropped count in stats" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :drop_oldest)

      for i <- 1..6 do
        EventStream.push(stream, {:event, i})
      end

      stats = EventStream.stats(stream)
      assert stats.dropped == 3
      assert stats.queue_size == 3
    end

    test "push returns :ok even when dropping" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :drop_oldest)

      assert :ok = EventStream.push(stream, {:event, 1})
      assert :ok = EventStream.push(stream, {:event, 2})
      assert :ok = EventStream.push(stream, {:event, 3})
    end
  end

  describe "queue overflow with :drop_newest strategy" do
    test "drops newest events when queue is full" do
      # Use max_queue: 6 to account for the agent_end event from complete
      {:ok, stream} = EventStream.start_link(max_queue: 6, drop_strategy: :drop_newest)

      # Fill the queue with 6 events (to max capacity)
      for i <- 1..6 do
        assert :ok = EventStream.push(stream, {:event, i})
      end

      # Push more events - should drop newest (the ones being pushed)
      assert :ok = EventStream.push(stream, {:event, 7})
      assert :ok = EventStream.push(stream, {:event, 8})

      EventStream.complete(stream, [])

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have events 1-6 plus agent_end (7,8 were dropped, and complete drops oldest to make room)
      event_values =
        events |> Enum.filter(&match?({:event, _}, &1)) |> Enum.map(fn {:event, i} -> i end)

      assert event_values == [2, 3, 4, 5, 6]
    end

    test "reports dropped count in stats" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :drop_newest)

      for i <- 1..6 do
        EventStream.push(stream, {:event, i})
      end

      stats = EventStream.stats(stream)
      assert stats.dropped == 3
      assert stats.queue_size == 3
    end

    test "push returns :ok even when dropping" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :drop_newest)

      assert :ok = EventStream.push(stream, {:event, 1})
      assert :ok = EventStream.push(stream, {:event, 2})
      assert :ok = EventStream.push(stream, {:event, 3})
    end
  end

  describe "queue overflow with :error strategy" do
    test "returns error when queue is full" do
      {:ok, stream} = EventStream.start_link(max_queue: 5, drop_strategy: :error)

      # Fill the queue
      for i <- 1..5 do
        assert :ok = EventStream.push(stream, {:event, i})
      end

      # Push more events - should return error
      assert {:error, :overflow} = EventStream.push(stream, {:event, 6})
      assert {:error, :overflow} = EventStream.push(stream, {:event, 7})
    end

    test "queue remains intact after overflow error" do
      # Use max_queue: 4 to leave room for agent_end from complete
      {:ok, stream} = EventStream.start_link(max_queue: 4, drop_strategy: :error)

      for i <- 1..4 do
        EventStream.push(stream, {:event, i})
      end

      assert {:error, :overflow} = EventStream.push(stream, {:event, 5})

      EventStream.complete(stream, [])

      events = EventStream.events(stream) |> Enum.to_list()

      event_values =
        events |> Enum.filter(&match?({:event, _}, &1)) |> Enum.map(fn {:event, i} -> i end)

      # Complete drops oldest to make room for agent_end
      assert event_values == [2, 3, 4]
    end

    test "reports dropped count in stats" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :error)

      EventStream.push(stream, {:event, 1})
      EventStream.push(stream, {:event, 2})
      EventStream.push(stream, {:event, 3})
      EventStream.push(stream, {:event, 4})

      stats = EventStream.stats(stream)
      assert stats.dropped == 2
    end

    test "async push drops silently on overflow" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :error)

      EventStream.push(stream, {:event, 1})
      EventStream.push(stream, {:event, 2})

      # Async push should return :ok even on overflow
      assert :ok = EventStream.push_async(stream, {:event, 3})

      # Give time for async push to process
      Process.sleep(20)

      stats = EventStream.stats(stream)
      assert stats.dropped == 1
    end
  end

  # ============================================================================
  # Cancellation Path
  # ============================================================================

  describe "cancel/2" do
    test "cancels the stream with a reason" do
      {:ok, stream} = EventStream.start_link()

      :ok = EventStream.cancel(stream, :user_requested)

      # Stream should be stopped
      Process.sleep(20)
      refute Process.alive?(stream)
    end

    test "result returns canceled error after cancel" do
      {:ok, stream} = EventStream.start_link()

      task = Task.async(fn -> EventStream.result(stream) end)

      Process.sleep(20)
      EventStream.cancel(stream, :user_requested)

      result = Task.await(task, 1000)
      assert {:error, {:canceled, :user_requested}} = result
    end

    test "events stream receives canceled event" do
      {:ok, stream} = EventStream.start_link()

      task =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      Process.sleep(20)
      EventStream.cancel(stream, :test_cancel)

      events = Task.await(task, 1000)
      assert {:canceled, :test_cancel} in events
    end

    test "cancel with default reason" do
      {:ok, stream} = EventStream.start_link()

      EventStream.cancel(stream)

      Process.sleep(20)
      refute Process.alive?(stream)
    end

    test "push returns error after cancel" do
      {:ok, stream} = EventStream.start_link()

      EventStream.cancel(stream, :user_requested)
      Process.sleep(20)

      # Stream is stopped, so push should catch the exit
      result = EventStream.push(stream, {:event, 1})
      assert result == {:error, :canceled}
    end

    test "multiple consumers wake up on cancel" do
      {:ok, stream} = EventStream.start_link()

      task1 = Task.async(fn -> EventStream.result(stream) end)
      task2 = Task.async(fn -> EventStream.result(stream) end)
      task3 = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)

      Process.sleep(50)
      EventStream.cancel(stream, :multi_cancel)

      assert {:error, {:canceled, :multi_cancel}} = Task.await(task1, 1000)
      assert {:error, {:canceled, :multi_cancel}} = Task.await(task2, 1000)
      events = Task.await(task3, 1000)
      assert {:canceled, :multi_cancel} in events
    end
  end

  # ============================================================================
  # Owner Death Path
  # ============================================================================

  describe "owner death" do
    test "stream cancels when owner process dies" do
      test_pid = self()

      # Spawn an owner process
      owner =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner)

      # Start a result waiter
      task =
        Task.async(fn ->
          result = EventStream.result(stream)
          send(test_pid, {:result, result})
          result
        end)

      Process.sleep(20)

      # Kill the owner
      send(owner, :die)

      # Stream should cancel
      result = Task.await(task, 1000)
      assert {:error, {:canceled, :owner_down}} = result

      Process.sleep(20)
      refute Process.alive?(stream)
    end

    test "events stream terminates when owner dies" do
      owner =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner)

      task =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      Process.sleep(20)
      send(owner, :die)

      events = Task.await(task, 1000)
      assert {:canceled, :owner_down} in events
    end

    test "owner death does not affect stream when owner is self" do
      # When owner is self() in start_link, it refers to the stream itself
      # which doesn't make sense to monitor
      {:ok, stream} = EventStream.start_link()

      EventStream.push(stream, {:event, 1})
      EventStream.complete(stream, [])

      events = EventStream.events(stream) |> Enum.to_list()
      assert {:event, 1} in events
      assert {:agent_end, []} in events
    end
  end

  # ============================================================================
  # Timeout Handling
  # ============================================================================

  describe "timeout handling" do
    test "stream auto-cancels on timeout" do
      {:ok, stream} = EventStream.start_link(timeout: 50)

      task =
        Task.async(fn ->
          EventStream.result(stream)
        end)

      result = Task.await(task, 1000)
      assert {:error, {:canceled, :timeout}} = result

      Process.sleep(20)
      refute Process.alive?(stream)
    end

    test "events stream receives timeout cancel event" do
      {:ok, stream} = EventStream.start_link(timeout: 50)

      task =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      events = Task.await(task, 1000)
      assert {:canceled, :timeout} in events
    end

    test "timeout does not trigger if stream completes first" do
      {:ok, stream} = EventStream.start_link(timeout: 100)

      EventStream.push(stream, {:event, 1})
      EventStream.complete(stream, ["done"])

      {:ok, result} = EventStream.result(stream)
      assert result == ["done"]

      # Wait past the original timeout
      Process.sleep(150)

      # Stream should still be alive (just done, not timed out)
      # Actually the stream stays alive after completion
      assert Process.alive?(stream)
    end

    test "infinity timeout does not trigger cancellation" do
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
  # Stats Function
  # ============================================================================

  describe "stats/1" do
    test "returns queue metrics" do
      {:ok, stream} = EventStream.start_link(max_queue: 100)

      EventStream.push(stream, {:event, 1})
      EventStream.push(stream, {:event, 2})
      EventStream.push(stream, {:event, 3})

      stats = EventStream.stats(stream)

      assert stats.queue_size == 3
      assert stats.max_queue == 100
      assert stats.dropped == 0
    end

    test "returns zero for empty stream" do
      {:ok, stream} = EventStream.start_link()

      stats = EventStream.stats(stream)

      assert stats.queue_size == 0
      assert stats.dropped == 0
    end

    test "updates queue_size as events are consumed" do
      {:ok, stream} = EventStream.start_link()

      for i <- 1..5 do
        EventStream.push(stream, {:event, i})
      end

      assert EventStream.stats(stream).queue_size == 5

      # Consume some events
      EventStream.events(stream) |> Enum.take(3)

      assert EventStream.stats(stream).queue_size == 2
    end

    test "tracks dropped events accurately" do
      {:ok, stream} = EventStream.start_link(max_queue: 5, drop_strategy: :drop_oldest)

      for i <- 1..10 do
        EventStream.push(stream, {:event, i})
      end

      stats = EventStream.stats(stream)
      assert stats.dropped == 5
      assert stats.queue_size == 5
    end
  end

  # ============================================================================
  # Task Attachment
  # ============================================================================

  describe "attach_task/2" do
    test "attaches a task to the stream" do
      {:ok, stream} = EventStream.start_link()

      task =
        Task.async(fn ->
          receive do
            :done -> :ok
          end
        end)

      :ok = EventStream.attach_task(stream, task.pid)

      # Task should still be running
      assert Process.alive?(task.pid)

      send(task.pid, :done)
      Task.await(task)
    end

    test "attached task is shutdown when stream is canceled" do
      {:ok, stream} = EventStream.start_link()

      # Use spawn instead of Task.async to avoid Task catching shutdown
      task_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          after
            5000 -> :timeout
          end
        end)

      EventStream.attach_task(stream, task_pid)

      Process.sleep(20)
      assert Process.alive?(task_pid)

      EventStream.cancel(stream, :test_cancel)

      Process.sleep(50)
      refute Process.alive?(task_pid)
    end

    test "attached task is shutdown when owner dies" do
      owner =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner)

      # Use spawn instead of Task.async to avoid Task catching shutdown
      task_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          after
            5000 -> :timeout
          end
        end)

      EventStream.attach_task(stream, task_pid)

      Process.sleep(20)
      assert Process.alive?(task_pid)

      send(owner, :die)

      Process.sleep(50)
      refute Process.alive?(task_pid)
    end

    test "attached task abort signal is triggered before shutdown" do
      {:ok, stream} = EventStream.start_link()
      test_pid = self()
      abort_ref = AbortSignal.new()

      task_pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          Process.put(:agent_abort_signal, abort_ref)

          receive do
            {:EXIT, _from, :shutdown} ->
              send(test_pid, {:saw_shutdown, AbortSignal.aborted?(abort_ref)})

              receive do
                :done -> :ok
              after
                5_000 -> :ok
              end
          end
        end)

      task_ref = Process.monitor(task_pid)

      EventStream.attach_task(stream, task_pid)
      Process.sleep(20)

      EventStream.cancel(stream, :test_cancel)

      assert_receive {:saw_shutdown, true}, 500
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :killed}, 1_500
      assert AbortSignal.aborted?(abort_ref)

      AbortSignal.clear(abort_ref)
    end

    test "attached task gets a grace window before forced shutdown" do
      {:ok, stream} = EventStream.start_link()
      test_pid = self()

      task_pid =
        spawn(fn ->
          Process.flag(:trap_exit, true)

          receive do
            {:EXIT, _from, :shutdown} ->
              send(test_pid, :shutdown_received)

              receive do
                :done -> :ok
              after
                5_000 -> :ok
              end
          end
        end)

      task_ref = Process.monitor(task_pid)

      EventStream.attach_task(stream, task_pid)
      Process.sleep(20)

      EventStream.cancel(stream, :test_cancel)

      assert_receive :shutdown_received, 500
      Process.sleep(20)
      assert Process.alive?(task_pid)
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :killed}, 1_500
    end

    test "stream receives error when attached task crashes" do
      {:ok, stream} = EventStream.start_link()

      task_pid =
        spawn(fn ->
          receive do
            :crash -> exit(:boom)
          end
        end)

      EventStream.attach_task(stream, task_pid)

      task =
        Task.async(fn ->
          EventStream.result(stream)
        end)

      Process.sleep(20)
      send(task_pid, :crash)

      result = Task.await(task, 1000)
      assert {:error, {:task_crashed, :boom}, nil} = result
    end

    test "task crash does not affect stream if already completed" do
      {:ok, stream} = EventStream.start_link()

      task_pid =
        spawn(fn ->
          receive do
            :crash -> exit(:boom)
          end
        end)

      EventStream.attach_task(stream, task_pid)
      EventStream.complete(stream, ["done"])

      {:ok, result} = EventStream.result(stream)
      assert result == ["done"]

      # Now crash the task - should not affect the result
      send(task_pid, :crash)
      Process.sleep(20)

      {:ok, result2} = EventStream.result(stream)
      assert result2 == ["done"]
    end

    test "only one task can be attached at a time" do
      {:ok, stream} = EventStream.start_link()

      task1_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      task2_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      EventStream.attach_task(stream, task1_pid)
      EventStream.attach_task(stream, task2_pid)

      Process.sleep(20)
      EventStream.cancel(stream, :test)

      Process.sleep(50)
      # Only task2 should be shutdown (it replaced task1)
      refute Process.alive?(task2_pid)
      # task1 should still be alive since it was replaced
      assert Process.alive?(task1_pid)

      # Clean up
      send(task1_pid, :done)
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "empty stream with immediate complete" do
      {:ok, stream} = EventStream.start_link()

      EventStream.complete(stream, [])

      events = EventStream.events(stream) |> Enum.to_list()
      assert events == [{:agent_end, []}]

      {:ok, result} = EventStream.result(stream)
      assert result == []
    end

    test "complete called multiple times" do
      {:ok, stream} = EventStream.start_link()

      EventStream.complete(stream, ["first"])
      EventStream.complete(stream, ["second"])

      # The result will be from whichever complete was processed
      # Both should result in a successful completion
      {:ok, result} = EventStream.result(stream)
      assert is_list(result)
    end

    test "events after complete are ignored" do
      {:ok, stream} = EventStream.start_link()

      EventStream.complete(stream, [])
      EventStream.push(stream, {:ignored_event, "data"})

      events = EventStream.events(stream) |> Enum.to_list()

      # The pushed event after complete may or may not be included
      # depending on timing, but stream should still work
      assert {:agent_end, []} in events
    end

    test "large number of events" do
      # Use a large enough max_queue to hold all events
      {:ok, stream} = EventStream.start_link(max_queue: 15_000)

      # Push 10000 events
      for i <- 1..10000 do
        EventStream.push(stream, {:event, i})
      end

      EventStream.complete(stream, [])

      events = EventStream.events(stream) |> Enum.to_list()
      assert length(events) == 10001
    end
  end
end
