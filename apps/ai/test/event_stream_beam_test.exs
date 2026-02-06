defmodule Ai.EventStreamBeamTest do
  @moduledoc """
  Tests for BEAM/OTP improvements to EventStream:
  - Owner monitoring
  - Task lifecycle management
  - Bounded queues and backpressure
  - Cancellation
  - Timeouts
  """

  use ExUnit.Case

  alias Ai.EventStream
  alias Ai.Types.{AssistantMessage, TextContent, Usage, Cost}

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

  defp wait_until(fun, timeout_ms \\ 200) do
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

  describe "owner monitoring" do
    test "stream cancels when owner dies" do
      test_pid = self()

      # Start a process that will own the stream and then die
      spawn(fn ->
        {:ok, stream} = EventStream.start_link(owner: self())
        send(test_pid, {:stream_pid, stream})
        # Die immediately after sending
      end)

      # Get the stream pid
      stream =
        receive do
          {:stream_pid, pid} -> pid
        after
          1000 -> flunk("Did not receive stream pid")
        end

      # Wait for owner to die and DOWN message to be processed
      Process.sleep(100)

      # Stream should have terminated
      refute Process.alive?(stream)
    end

    test "stream survives when owner is self" do
      {:ok, stream} = EventStream.start_link()

      # Push some events
      EventStream.push_async(stream, {:text_delta, 0, "test", make_message()})

      # Stream should still be alive
      assert Process.alive?(stream)

      EventStream.complete(stream, make_message())
    end

    test "stream with explicit owner survives owner" do
      test_pid = self()

      {:ok, stream} = EventStream.start_link(owner: test_pid)

      # Stream should be alive
      assert Process.alive?(stream)

      EventStream.complete(stream, make_message())
    end
  end

  describe "task attachment and lifecycle" do
    test "attached task is monitored" do
      {:ok, stream} = EventStream.start_link()

      # Start a task
      task =
        Task.async(fn ->
          Process.sleep(50)
          EventStream.complete(stream, make_message())
        end)

      EventStream.attach_task(stream, task.pid)

      # Wait for completion
      {:ok, _result} = EventStream.result(stream, 5000)
    end

    test "stream reports error when attached task crashes" do
      {:ok, stream} = EventStream.start_link()

      # Start a task that will crash
      {:ok, task_pid} =
        Task.start(fn ->
          Process.sleep(50)
          raise "intentional crash"
        end)

      EventStream.attach_task(stream, task_pid)

      # The stream should receive an error
      result = EventStream.result(stream, 5000)

      assert {:error, %AssistantMessage{stop_reason: :error}} = result
    end

    test "task is shutdown when stream is canceled" do
      {:ok, stream} = EventStream.start_link()

      # Start a long-running task
      task_ref = make_ref()
      test_pid = self()

      {:ok, task_pid} =
        Task.start(fn ->
          send(test_pid, {:task_started, task_ref})

          receive do
            :never -> :ok
          end
        end)

      EventStream.attach_task(stream, task_pid)

      # Wait for task to start
      assert_receive {:task_started, ^task_ref}, 1000

      # Cancel the stream
      EventStream.cancel(stream, :test_cancel)

      # Task should be terminated
      Process.sleep(100)
      refute Process.alive?(task_pid)
    end
  end

  describe "waiter ordering" do
    test "result waiters do not block event delivery" do
      {:ok, stream} = EventStream.start_link()

      result_task =
        Task.async(fn ->
          EventStream.result(stream, 5000)
        end)

      assert wait_until(fn ->
               state = :sys.get_state(stream)
               :queue.len(state.result_waiters) == 1
             end),
             "result waiter did not register"

      take_task =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.take(1)
        end)

      assert wait_until(fn ->
               state = :sys.get_state(stream)
               :queue.len(state.take_waiters) == 1
             end),
             "take waiter did not register"

      partial = make_message()
      assert :ok = EventStream.push(stream, {:text_delta, 0, "Hello", partial})
      EventStream.complete(stream, make_message())

      events = Task.await(take_task, 1000)
      assert [{:text_delta, 0, "Hello", _}] = events

      assert {:ok, _} = Task.await(result_task, 1000)
    end
  end

  describe "bounded queue and backpressure" do
    test "queue respects max_queue limit with :error strategy" do
      {:ok, stream} = EventStream.start_link(max_queue: 5, drop_strategy: :error)

      partial = make_message()

      # Fill the queue
      for i <- 1..5 do
        assert :ok = EventStream.push(stream, {:text_delta, 0, "#{i}", partial})
      end

      # Next push should overflow
      assert {:error, :overflow} = EventStream.push(stream, {:text_delta, 0, "6", partial})

      # Stats should show queue at max
      stats = EventStream.stats(stream)
      assert stats.queue_size == 5
      assert stats.max_queue == 5
    end

    test "overflow increments dropped count with :error strategy" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :error)

      partial = make_message()

      assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_1", partial})
      assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_2", partial})
      assert {:error, :overflow} = EventStream.push(stream, {:text_delta, 0, "msg_3", partial})

      stats = EventStream.stats(stream)
      assert stats.queue_size == 2
      assert stats.dropped == 1
    end

    test "terminal event is delivered even when queue is full with :error strategy" do
      {:ok, stream} = EventStream.start_link(max_queue: 2, drop_strategy: :error)

      partial = make_message()

      # Fill the queue
      assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_1", partial})
      assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_2", partial})

      # Complete should still enqueue terminal event by dropping the oldest
      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()

      assert Enum.any?(events, &match?({:done, :stop, _}, &1))

      text_events = Enum.filter(events, &match?({:text_delta, _, _, _}, &1))
      assert length(text_events) == 1

      stats = EventStream.stats(stream)
      assert stats.dropped == 1
    end

    test "queue drops oldest with :drop_oldest strategy" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :drop_oldest)

      partial = make_message()

      # Fill and overflow: push 5 events with max_queue=3
      # After all pushes: queue=[3,4,5], dropped=2
      for i <- 1..5 do
        assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      # complete() adds done event, drops oldest (msg_3)
      # Final queue=[4,5,done], dropped=3
      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have 2 text events (4 and 5) plus done
      text_events = Enum.filter(events, &match?({:text_delta, _, _, _}, &1))
      assert length(text_events) == 2

      # Check stats for dropped count (3 events dropped: 1, 2, and 3)
      stats = EventStream.stats(stream)
      assert stats.dropped == 3
    end

    test "queue drops newest with :drop_newest strategy" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :drop_newest)

      partial = make_message()

      # Fill and overflow: push 5 events with max_queue=3
      # Events 1,2,3 go in queue, events 4,5 are dropped
      for i <- 1..5 do
        assert :ok = EventStream.push(stream, {:text_delta, 0, "msg_#{i}", partial})
      end

      # complete() forces room for the terminal event by dropping the oldest
      # Final queue=[2,3,done], dropped=3 (events 4,5 and msg_1)
      EventStream.complete(stream, make_message())

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have kept events 2 and 3, plus the done event
      text_events = Enum.filter(events, &match?({:text_delta, _, _, _}, &1))
      assert length(text_events) == 2
      assert Enum.any?(events, &match?({:done, :stop, _}, &1))

      # 3 events dropped: 4, 5, and msg_1 (to make room for done)
      stats = EventStream.stats(stream)
      assert stats.dropped == 3
    end

    test "push_async ignores backpressure" do
      {:ok, stream} = EventStream.start_link(max_queue: 3, drop_strategy: :error)

      partial = make_message()

      # Push more than max_queue with async
      for i <- 1..10 do
        EventStream.push_async(stream, {:text_delta, 0, "#{i}", partial})
      end

      # Async push doesn't return errors, but events may be dropped
      EventStream.complete(stream, make_message())

      # Stream should complete without error
      {:ok, _} = EventStream.result(stream)
    end

    test "push_async increments dropped count on overflow with :error strategy" do
      {:ok, stream} = EventStream.start_link(max_queue: 1, drop_strategy: :error)

      partial = make_message()

      EventStream.push_async(stream, {:text_delta, 0, "msg_1", partial})
      EventStream.push_async(stream, {:text_delta, 0, "msg_2", partial})

      assert wait_until(fn ->
               stats = EventStream.stats(stream)
               stats.queue_size == 1 and stats.dropped == 1
             end),
             "expected dropped count to increment after async overflow"

      EventStream.complete(stream, make_message())
      {:ok, _} = EventStream.result(stream)
    end
  end

  describe "cancellation" do
    test "cancel/2 stops the stream" do
      {:ok, stream} = EventStream.start_link()

      EventStream.push_async(stream, {:text_delta, 0, "hello", make_message()})

      # Cancel
      EventStream.cancel(stream, :user_canceled)

      # Stream should be stopped
      Process.sleep(50)
      refute Process.alive?(stream)
    end

    test "cancel emits canceled event" do
      {:ok, stream} = EventStream.start_link()

      partial = make_message()
      EventStream.push_async(stream, {:text_delta, 0, "hello", partial})

      # Start reader in background
      reader =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      # Give reader time to start waiting
      Process.sleep(20)

      # Cancel
      EventStream.cancel(stream, :test_reason)

      events = Task.await(reader, 1000)

      # Should have text_delta and canceled events
      assert Enum.any?(events, &match?({:text_delta, _, _, _}, &1))
      assert Enum.any?(events, &match?({:canceled, :test_reason}, &1))
    end

    test "result returns error after cancellation" do
      {:ok, stream} = EventStream.start_link()

      # Cancel before any events
      EventStream.cancel(stream, :early_cancel)

      # result should return the cancel error
      # Note: we need to call result before the stream stops
      # so let's use a longer-lived approach

      {:ok, stream2} = EventStream.start_link()

      reader =
        Task.async(fn ->
          EventStream.result(stream2, 5000)
        end)

      Process.sleep(20)
      EventStream.cancel(stream2, :test_cancel)

      result = Task.await(reader, 1000)
      assert {:error, {:canceled, :test_cancel}} = result
    end

    test "push returns error after cancellation" do
      {:ok, stream} = EventStream.start_link()

      EventStream.cancel(stream, :canceled)

      # Give time for cancellation to process and stream to stop
      Process.sleep(50)

      # Push should return canceled error
      result = EventStream.push(stream, {:text_delta, 0, "test", make_message()})
      assert {:error, :canceled} = result
    end
  end

  describe "timeouts" do
    test "stream times out after configured duration" do
      {:ok, stream} = EventStream.start_link(timeout: 100)

      # Don't complete the stream, let it timeout
      Process.sleep(200)

      # Stream should have terminated
      refute Process.alive?(stream)
    end

    test "timeout emits canceled event with :timeout reason" do
      {:ok, stream} = EventStream.start_link(timeout: 100)

      reader =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      events = Task.await(reader, 1000)

      # Should have timeout cancellation
      assert Enum.any?(events, &match?({:canceled, :timeout}, &1))
    end

    test "completing stream cancels timeout" do
      {:ok, stream} = EventStream.start_link(timeout: 200)

      # Complete immediately
      EventStream.complete(stream, make_message())

      # Wait past the timeout
      Process.sleep(300)

      # result should return the message, not a timeout
      {:ok, result} = EventStream.result(stream)
      assert result.stop_reason == :stop
    end

    test "infinite timeout doesn't trigger" do
      {:ok, stream} = EventStream.start_link(timeout: :infinity)

      # Stream should stay alive
      Process.sleep(100)
      assert Process.alive?(stream)

      EventStream.complete(stream, make_message())
    end
  end

  describe "stats" do
    test "stats returns queue information" do
      {:ok, stream} = EventStream.start_link(max_queue: 100)

      partial = make_message()

      for i <- 1..10 do
        EventStream.push_async(stream, {:text_delta, 0, "#{i}", partial})
      end

      stats = EventStream.stats(stream)

      assert stats.queue_size == 10
      assert stats.max_queue == 100
      assert stats.dropped == 0
    end
  end

  describe "backward compatibility" do
    test "start_link with no options works" do
      {:ok, stream} = EventStream.start_link()
      assert is_pid(stream)
      EventStream.complete(stream, make_message())
    end

    test "events enumerable still works" do
      {:ok, stream} = EventStream.start_link()

      partial = make_message()
      EventStream.push_async(stream, {:text_delta, 0, "Hello", partial})
      EventStream.push_async(stream, {:text_delta, 0, " World", partial})
      EventStream.complete(stream, make_message(content: [%TextContent{text: "Hello World"}]))

      events = EventStream.events(stream) |> Enum.to_list()

      assert length(events) == 3
      assert {:text_delta, 0, "Hello", _} = Enum.at(events, 0)
      assert {:text_delta, 0, " World", _} = Enum.at(events, 1)
      assert {:done, :stop, _} = Enum.at(events, 2)
    end

    test "collect_text still works" do
      {:ok, stream} = EventStream.start_link()

      partial = make_message()
      EventStream.push_async(stream, {:text_delta, 0, "Hello", partial})
      EventStream.push_async(stream, {:text_delta, 0, " ", partial})
      EventStream.push_async(stream, {:text_delta, 0, "World!", partial})
      EventStream.complete(stream, make_message())

      text = EventStream.collect_text(stream)
      assert text == "Hello World!"
    end
  end
end
