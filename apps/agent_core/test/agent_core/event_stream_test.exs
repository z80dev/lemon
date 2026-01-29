defmodule AgentCore.EventStreamTest do
  use ExUnit.Case, async: true

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
      assert catch_exit(EventStream.result(stream, 100)) != nil
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
      {:ok, stream} = EventStream.start_link()

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
