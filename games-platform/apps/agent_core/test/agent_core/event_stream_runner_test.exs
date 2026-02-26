defmodule AgentCore.EventStreamRunnerTest do
  @moduledoc """
  Tests for EventStream runner process monitoring.

  These tests verify that when the producer (runner) process dies,
  the EventStream properly emits an error event and wakes up waiting consumers.
  This prevents consumers from blocking forever on a dead producer.
  """
  use ExUnit.Case, async: true

  alias AgentCore.EventStream

  # ============================================================================
  # Runner Monitoring - Basic Functionality
  # ============================================================================

  describe "runner monitoring" do
    test "stream with runner option starts successfully" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)
      assert is_pid(stream)
      assert Process.alive?(stream)

      send(runner, :done)
    end

    test "stream can have both owner and runner" do
      owner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner, runner: runner)
      assert is_pid(stream)
      assert Process.alive?(stream)

      send(owner, :done)
      send(runner, :done)
    end

    test "stream works normally when runner stays alive" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Push events and complete normally
      EventStream.push(stream, {:event, 1})
      EventStream.push(stream, {:event, 2})
      EventStream.complete(stream, ["result"])

      events = EventStream.events(stream) |> Enum.to_list()
      assert {:event, 1} in events
      assert {:event, 2} in events
      assert {:agent_end, ["result"]} in events

      send(runner, :done)
    end
  end

  # ============================================================================
  # Runner Crash Scenarios - Consumer Waiting
  # ============================================================================

  describe "runner crash wakes waiting consumer" do
    test "consumer blocked on events/1 receives error when runner crashes" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Start consumer that will block waiting for events
      consumer =
        Task.async(fn ->
          EventStream.events(stream) |> Enum.to_list()
        end)

      # Give consumer time to block
      Process.sleep(50)

      # Kill the runner
      Process.exit(runner, :kill)

      # Consumer should receive error event and complete
      events = Task.await(consumer, 1000)

      # Should have terminal error event
      assert Enum.any?(events, fn
               {:error, {:runner_crashed, :killed}, _} -> true
               _ -> false
             end)
    end

    test "result/1 waiter receives error when runner crashes" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Start result waiter
      waiter =
        Task.async(fn ->
          EventStream.result(stream)
        end)

      Process.sleep(50)

      # Kill the runner
      Process.exit(runner, :kill)

      # Waiter should receive error
      assert {:error, {:runner_crashed, :killed}, nil} = Task.await(waiter, 1000)
    end

    test "multiple consumers all complete when runner crashes" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Start multiple consumers
      consumers =
        for _ <- 1..5 do
          Task.async(fn ->
            EventStream.events(stream) |> Enum.to_list()
          end)
        end

      Process.sleep(50)

      # Kill the runner
      Process.exit(runner, :kill)

      # All consumers should complete (at least one gets the error)
      all_events =
        for task <- consumers do
          Task.await(task, 1000)
        end
        |> List.flatten()

      # Combined events should have the error
      assert Enum.any?(all_events, fn
               {:error, {:runner_crashed, :killed}, _} -> true
               _ -> false
             end)
    end

    test "multiple result waiters all receive error when runner crashes" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Start multiple result waiters
      waiters =
        for _ <- 1..5 do
          Task.async(fn ->
            EventStream.result(stream)
          end)
        end

      Process.sleep(50)

      # Kill the runner
      Process.exit(runner, :kill)

      # All waiters should receive error
      for task <- waiters do
        assert {:error, {:runner_crashed, :killed}, nil} = Task.await(task, 1000)
      end
    end
  end

  # ============================================================================
  # Runner Crash Scenarios - Consumer Not Yet Waiting
  # ============================================================================

  describe "runner crash before consumer starts" do
    test "consumer receives error when runner crashed before events/1" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Push some events first
      EventStream.push(stream, {:event, 1})

      # Kill the runner
      Process.exit(runner, :kill)
      Process.sleep(50)

      # Consumer starts after runner is dead
      events = EventStream.events(stream) |> Enum.to_list()

      # Should still receive error event
      assert Enum.any?(events, fn
               {:error, {:runner_crashed, :killed}, _} -> true
               _ -> false
             end)
    end

    test "result/1 receives error when runner crashed before call" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Kill the runner
      Process.exit(runner, :kill)
      Process.sleep(50)

      # result/1 called after runner is dead
      assert {:error, {:runner_crashed, :killed}, nil} = EventStream.result(stream)
    end
  end

  # ============================================================================
  # Runner Crash Scenarios - Different Crash Reasons
  # ============================================================================

  describe "runner crash reasons are preserved" do
    test "normal exit is reported as :normal" do
      # Use a runner that we can control the exit of
      runner =
        spawn(fn ->
          receive do
            :exit -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      consumer = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)
      Process.sleep(50)

      # Signal runner to exit normally
      send(runner, :exit)

      events = Task.await(consumer, 2000)

      assert Enum.any?(events, fn
               {:error, {:runner_crashed, :normal}, _} -> true
               _ -> false
             end)
    end

    test "shutdown exit is reported as :shutdown" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      consumer = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)
      Process.sleep(50)

      Process.exit(runner, :shutdown)

      events = Task.await(consumer, 1000)

      assert Enum.any?(events, fn
               {:error, {:runner_crashed, :shutdown}, _} -> true
               _ -> false
             end)
    end

    test "custom reason is preserved" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      consumer = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)
      Process.sleep(50)

      Process.exit(runner, :my_custom_reason)

      events = Task.await(consumer, 1000)

      assert Enum.any?(events, fn
               {:error, {:runner_crashed, :my_custom_reason}, _} -> true
               _ -> false
             end)
    end
  end

  # ============================================================================
  # Runner Does Not Crash After Completion
  # ============================================================================

  describe "runner crash after completion is ignored" do
    test "runner crash after complete/1 does not emit error" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Complete normally
      EventStream.complete(stream, ["result"])

      # Then kill runner
      Process.exit(runner, :kill)

      events = EventStream.events(stream) |> Enum.to_list()

      # Should only have completion, not error
      assert {:agent_end, ["result"]} in events

      refute Enum.any?(events, fn
               {:error, {:runner_crashed, _}, _} -> true
               _ -> false
             end)
    end

    test "runner crash after error/1 does not emit another error" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Emit error first
      EventStream.error(stream, :my_error, nil)

      # Then kill runner
      Process.exit(runner, :kill)

      events = EventStream.events(stream) |> Enum.to_list()

      # Should only have the original error
      assert {:error, :my_error, nil} in events

      refute Enum.any?(events, fn
               {:error, {:runner_crashed, _}, _} -> true
               _ -> false
             end)
    end

    test "runner crash after cancel/1 does not emit error" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Cancel first
      EventStream.cancel(stream, :user_cancel)

      # Give time for cancel to process
      Process.sleep(50)

      # Stream should be dead (cancel stops it)
      refute Process.alive?(stream)

      # Clean up runner
      send(runner, :done)
    end
  end

  # ============================================================================
  # Runner + Owner Interaction
  # ============================================================================

  describe "runner and owner interaction" do
    test "owner dying cancels stream even if runner is alive" do
      owner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner, runner: runner)

      consumer = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)
      Process.sleep(50)

      # Kill owner, runner stays alive
      Process.exit(owner, :kill)

      # Consumer should receive canceled
      events = Task.await(consumer, 1000)

      assert Enum.any?(events, fn
               {:canceled, :owner_down} -> true
               _ -> false
             end)

      # Clean up
      send(runner, :done)
    end

    test "runner dying errors stream even if owner is alive" do
      owner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(owner: owner, runner: runner)

      consumer = Task.async(fn -> EventStream.events(stream) |> Enum.to_list() end)
      Process.sleep(50)

      # Kill runner, owner stays alive
      Process.exit(runner, :kill)

      # Consumer should receive error
      events = Task.await(consumer, 1000)

      assert Enum.any?(events, fn
               {:error, {:runner_crashed, :killed}, _} -> true
               _ -> false
             end)

      # Clean up
      send(owner, :done)
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "runner monitoring edge cases" do
    test "runner that exits normally is treated as crashed" do
      # Use a runner that waits for signal then exits normally
      runner =
        spawn(fn ->
          receive do
            :exit -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Signal normal exit
      send(runner, :exit)
      Process.sleep(50)

      # Consumer should receive error even for normal exit
      events = EventStream.events(stream) |> Enum.to_list()

      assert Enum.any?(events, fn
               {:error, {:runner_crashed, :normal}, _} -> true
               _ -> false
             end)
    end

    test "dead runner at start time emits error immediately" do
      # Start runner and signal it to exit, then create stream
      runner =
        spawn(fn ->
          receive do
            :exit -> :ok
          end
        end)

      send(runner, :exit)
      Process.sleep(50)
      refute Process.alive?(runner)

      {:ok, stream} = EventStream.start_link(runner: runner)

      Process.sleep(50)

      # Consumer should still receive error (monitor fires immediately for dead process)
      # Note: reason will be :noproc since process was already dead
      events = EventStream.events(stream) |> Enum.to_list()

      assert Enum.any?(events, fn
               {:error, {:runner_crashed, _}, _} -> true
               _ -> false
             end)
    end

    test "events pushed before runner crash are still received" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      # Push some events
      EventStream.push(stream, {:event, 1})
      EventStream.push(stream, {:event, 2})
      EventStream.push(stream, {:event, 3})

      # Kill runner
      Process.exit(runner, :kill)

      # Consumer should get pushed events plus error
      events = EventStream.events(stream) |> Enum.to_list()

      assert {:event, 1} in events
      assert {:event, 2} in events
      assert {:event, 3} in events

      assert Enum.any?(events, fn
               {:error, {:runner_crashed, :killed}, _} -> true
               _ -> false
             end)
    end

    test "stream stays alive after runner crash for consumers to read" do
      runner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      {:ok, stream} = EventStream.start_link(runner: runner)

      Process.exit(runner, :kill)
      Process.sleep(50)

      # Stream should stay alive so consumers can read the error
      assert Process.alive?(stream)

      # Consumer can still read the error
      events = EventStream.events(stream) |> Enum.to_list()

      assert Enum.any?(events, fn
               {:error, {:runner_crashed, :killed}, _} -> true
               _ -> false
             end)
    end
  end

  # ============================================================================
  # Integration with Real Producer Pattern
  # ============================================================================

  describe "integration with producer-consumer pattern" do
    test "simulates JsonlRunner crash scenario" do
      # Simulate the JsonlRunner pattern:
      # 1. Runner creates stream with runner: self()
      # 2. Runner pushes events
      # 3. Runner crashes before completing
      # 4. Consumer should receive error

      test_pid = self()

      # Use an Agent or intermediary to hold the stream pid so we can
      # start the runner without trapping exits
      {:ok, stream_holder} = Agent.start(fn -> nil end)

      # Simulate runner process (without trap_exit - like real JsonlRunner)
      runner =
        spawn(fn ->
          # Use start (not start_link) to avoid link, just like JsonlRunner
          {:ok, stream} = EventStream.start(runner: self())

          # Push some events
          EventStream.push(stream, {:cli_event, %{type: :started}})
          EventStream.push(stream, {:cli_event, %{type: :thinking}})

          # Store stream pid
          Agent.update(stream_holder, fn _ -> stream end)
          send(test_pid, :stream_ready)

          # Wait for crash signal - when we get it, we'll raise an exception
          # (not using Process.exit because that behaves differently with trap_exit)
          receive do
            :crash ->
              # Simulate a real crash (like a bug in the runner)
              raise "Simulated runner crash"
          end
        end)

      # Wait for stream to be created
      assert_receive :stream_ready, 1000

      # Get the stream from the holder
      stream = Agent.get(stream_holder, & &1)
      assert is_pid(stream)

      # Give runner time to set up
      Process.sleep(50)

      # Crash the runner (this will cause it to raise)
      send(runner, :crash)

      # Wait for runner to die and EventStream to handle it
      Process.sleep(100)

      # Verify EventStream is still alive (it traps exits)
      assert Process.alive?(stream), "EventStream should still be alive after runner crash"

      # Now consume events (after crash is handled)
      events = EventStream.events(stream) |> Enum.to_list()

      assert {:cli_event, %{type: :started}} in events
      assert {:cli_event, %{type: :thinking}} in events
      # The error reason will be the exception tuple
      assert Enum.any?(events, fn
               {:error, {:runner_crashed, {%RuntimeError{message: "Simulated runner crash"}, _}},
                _} ->
                 true

               _ ->
                 false
             end)

      Agent.stop(stream_holder)
    end
  end
end
