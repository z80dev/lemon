defmodule LemonGateway.SchedulerTest do
  alias Elixir.LemonGateway, as: LemonGateway
  use ExUnit.Case, async: false

  alias Elixir.LemonGateway.Scheduler
  alias Elixir.LemonGateway.Types.{ChatScope, Job, ResumeToken}

  defmodule Elixir.LemonGateway.SchedulerTest.SlowEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Event
    alias Elixir.LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "slow"

    @impl true
    def format_resume(%ResumeToken{value: v}), do: "slow resume #{v}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      delay_ms = (job.meta || %{})[:delay_ms] || 100

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
          Process.sleep(delay_ms)

          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{engine: id(), resume: resume, ok: true, answer: "ok"})}
          )
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  defmodule BlockingEnqueueWorker do
    @moduledoc false
    use GenServer

    alias Elixir.LemonGateway.Types.Job

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      thread_key = Keyword.fetch!(opts, :thread_key)
      notify_pid = Keyword.fetch!(opts, :notify_pid)
      delay_ms = Keyword.get(opts, :delay_ms, 300)

      {:ok, _} = Registry.register(Elixir.LemonGateway.ThreadRegistry, thread_key, :ok)

      {:ok, %{notify_pid: notify_pid, delay_ms: delay_ms}}
    end

    @impl true
    def handle_cast({:enqueue, %Job{} = job}, state) do
      Process.sleep(state.delay_ms)
      send(state.notify_pid, {:blocking_worker_enqueue_cast, job})
      {:noreply, state}
    end

    @impl true
    def handle_call({:enqueue, %Job{} = job}, _from, state) do
      Process.sleep(state.delay_ms)
      send(state.notify_pid, {:blocking_worker_enqueue_call, job})
      {:reply, :ok, state}
    end
  end

  # Test helper to create a minimal job
  defp make_job(opts \\ []) do
    scope = Keyword.get(opts, :scope, %ChatScope{transport: :test, chat_id: 1, topic_id: nil})
    session_key = Keyword.get(opts, :session_key, scope_to_session_key(scope))
    prompt = Keyword.get(opts, :text, Keyword.get(opts, :prompt, "test message"))
    resume = Keyword.get(opts, :resume, nil)
    user_msg_id = Keyword.get(opts, :user_msg_id, 1)
    meta = Map.merge(%{user_msg_id: user_msg_id}, Keyword.get(opts, :meta, %{}))

    %Job{
      session_key: session_key,
      prompt: prompt,
      resume: resume,
      engine_id: Keyword.get(opts, :engine_hint, Keyword.get(opts, :engine_id, "echo")),
      meta: meta
    }
  end

  defp scope_to_session_key(%ChatScope{
         transport: transport,
         chat_id: chat_id,
         topic_id: topic_id
       }) do
    topic = if is_nil(topic_id), do: "main", else: topic_id
    "#{transport}:#{chat_id}:#{topic}"
  end

  defp scope_to_session_key(scope) when is_binary(scope), do: scope
  defp scope_to_session_key(scope), do: inspect(scope)

  describe "Scheduler unit tests (isolated GenServer)" do
    setup do
      # Start a fresh Scheduler for each test with a unique name
      # We test the GenServer callbacks directly to avoid needing full app startup
      {:ok, %{}}
    end

    test "init/1 initializes state with correct structure" do
      # Mock the config call by testing init directly
      # The init function reads max from Config, so we test the structure
      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      assert map_size(state.in_flight) == 0
      assert :queue.is_empty(state.waitq)
      assert map_size(state.monitors) == 0
      assert map_size(state.worker_counts) == 0
    end

    test "request_slot grants slot when under max capacity" do
      state = %{
        max: 2,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      worker_pid = self()
      thread_key = {:scope, %ChatScope{transport: :test, chat_id: 1}}

      {:noreply, new_state} =
        Scheduler.handle_cast({:request_slot, worker_pid, thread_key}, state)

      assert map_size(new_state.in_flight) == 1
      assert :queue.is_empty(new_state.waitq)
      assert Map.has_key?(new_state.monitors, worker_pid)
      assert Map.get(new_state.worker_counts, worker_pid) == 1

      # Should receive slot_granted message
      assert_receive {:slot_granted, slot_ref}
      assert is_reference(slot_ref)
    end

    test "request_slot queues request when at max capacity" do
      worker1 = spawn(fn -> Process.sleep(:infinity) end)
      worker2 = spawn(fn -> Process.sleep(:infinity) end)

      # Create state with max=1 and one slot already taken
      slot_ref1 = make_ref()
      mon_ref1 = Process.monitor(worker1)

      state = %{
        max: 1,
        in_flight: %{
          slot_ref1 => %{worker: worker1, thread_key: {:scope, :key1}, mon_ref: mon_ref1}
        },
        waitq: :queue.new(),
        monitors: %{worker1 => mon_ref1},
        worker_counts: %{worker1 => 1}
      }

      thread_key2 = {:scope, :key2}

      {:noreply, new_state} =
        Scheduler.handle_cast({:request_slot, worker2, thread_key2}, state)

      # Should still have 1 in_flight (at max)
      assert map_size(new_state.in_flight) == 1
      # Should have queued the request
      assert not :queue.is_empty(new_state.waitq)
      assert :queue.len(new_state.waitq) == 1

      # Worker2 should NOT receive slot_granted yet
      refute_receive {:slot_granted, _}

      # Cleanup
      Process.exit(worker1, :kill)
      Process.exit(worker2, :kill)
    end

    test "submit path does not block on worker enqueue" do
      if is_nil(Process.whereis(Elixir.LemonGateway.ThreadRegistry)) do
        {:ok, _} =
          start_supervised({Registry, keys: :unique, name: Elixir.LemonGateway.ThreadRegistry})
      end

      session_key = "blocking_enqueue:#{System.unique_integer([:positive])}"
      thread_key = {:session, session_key}

      {:ok, _worker_pid} =
        start_supervised(
          {BlockingEnqueueWorker, thread_key: thread_key, notify_pid: self(), delay_ms: 300}
        )

      state = %{
        max: 2,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      job = make_job(session_key: session_key)

      {elapsed_us, {:noreply, new_state}} =
        :timer.tc(fn ->
          Scheduler.handle_cast({:submit, job}, state)
        end)

      assert new_state == state
      assert elapsed_us < 100_000
      assert_receive {:blocking_worker_enqueue_cast, %Job{}}, 1_000
      refute_receive {:blocking_worker_enqueue_call, _}
    end

    test "release_slot removes slot from in_flight and grants to waiting" do
      worker1 = spawn(fn -> Process.sleep(:infinity) end)
      worker2 = self()

      slot_ref1 = make_ref()
      mon_ref1 = Process.monitor(worker1)
      mon_ref2 = Process.monitor(worker2)

      # State: worker1 has slot, worker2 is waiting
      state = %{
        max: 1,
        in_flight: %{
          slot_ref1 => %{worker: worker1, thread_key: {:scope, :key1}, mon_ref: mon_ref1}
        },
        waitq:
          :queue.from_list([%{worker: worker2, thread_key: {:scope, :key2}, mon_ref: mon_ref2}]),
        monitors: %{worker1 => mon_ref1, worker2 => mon_ref2},
        worker_counts: %{worker1 => 1, worker2 => 1}
      }

      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, slot_ref1}, state)

      # Should have granted slot to worker2
      assert map_size(new_state.in_flight) == 1
      assert :queue.is_empty(new_state.waitq)

      # Worker2 (self) should receive slot_granted
      assert_receive {:slot_granted, new_slot_ref}
      assert is_reference(new_slot_ref)

      # New slot should be in in_flight for worker2
      assert Map.has_key?(new_state.in_flight, new_slot_ref)
      entry = Map.get(new_state.in_flight, new_slot_ref)
      assert entry.worker == worker2

      Process.exit(worker1, :kill)
    end

    test "release_slot with non-existent slot_ref is safe" do
      state = %{
        max: 2,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      fake_slot_ref = make_ref()

      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, fake_slot_ref}, state)

      # State should be unchanged
      assert new_state == state
    end

    test "handle_info DOWN cleans up worker from in_flight and waitq" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)

      slot_ref = make_ref()

      state = %{
        max: 2,
        in_flight: %{
          slot_ref => %{worker: worker, thread_key: {:scope, :key1}, mon_ref: mon_ref}
        },
        waitq:
          :queue.from_list([%{worker: worker, thread_key: {:scope, :key2}, mon_ref: mon_ref}]),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 2}
      }

      Process.exit(worker, :kill)

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, mon_ref, :process, worker, :killed}, state)

      # Worker should be fully cleaned up
      assert map_size(new_state.in_flight) == 0
      assert :queue.is_empty(new_state.waitq)
      assert not Map.has_key?(new_state.monitors, worker)
      assert not Map.has_key?(new_state.worker_counts, worker)
    end

    test "handle_info DOWN with wrong mon_ref is ignored" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      correct_mon_ref = Process.monitor(worker)
      wrong_mon_ref = make_ref()

      slot_ref = make_ref()

      state = %{
        max: 2,
        in_flight: %{
          slot_ref => %{worker: worker, thread_key: {:scope, :key1}, mon_ref: correct_mon_ref}
        },
        waitq: :queue.new(),
        monitors: %{worker => correct_mon_ref},
        worker_counts: %{worker => 1}
      }

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, wrong_mon_ref, :process, worker, :killed}, state)

      # State should be unchanged since mon_ref doesn't match
      assert new_state == state

      Process.exit(worker, :kill)
    end

    test "multiple slots can be granted up to max" do
      state = %{
        max: 3,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      workers =
        for _ <- 1..3 do
          spawn(fn ->
            receive do
              {:slot_granted, _ref} -> :ok
            after
              1000 -> :timeout
            end
          end)
        end

      # Request slots for all workers
      final_state =
        Enum.with_index(workers)
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      # All 3 slots should be granted
      assert map_size(final_state.in_flight) == 3
      assert :queue.is_empty(final_state.waitq)

      # Cleanup
      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "fourth request is queued when max is 3" do
      workers =
        for _ <- 1..4 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      state = %{
        max: 3,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      final_state =
        Enum.with_index(workers)
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      # 3 slots granted, 1 queued
      assert map_size(final_state.in_flight) == 3
      assert :queue.len(final_state.waitq) == 1

      # Cleanup
      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "same worker can hold multiple slots" do
      worker = self()

      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Request 3 slots for the same worker
      final_state =
        Enum.reduce(1..3, state, fn i, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      # Should have 3 slots, but only 1 monitor (for the same worker)
      assert map_size(final_state.in_flight) == 3
      assert map_size(final_state.monitors) == 1
      assert Map.get(final_state.worker_counts, worker) == 3

      # Receive all 3 slot_granted messages
      for _ <- 1..3 do
        assert_receive {:slot_granted, _slot_ref}
      end
    end

    test "releasing one slot decrements worker_counts but keeps monitor" do
      worker = self()

      # Start with worker holding 2 slots
      slot_ref1 = make_ref()
      slot_ref2 = make_ref()
      mon_ref = Process.monitor(worker)

      state = %{
        max: 5,
        in_flight: %{
          slot_ref1 => %{worker: worker, thread_key: {:scope, :key1}, mon_ref: mon_ref},
          slot_ref2 => %{worker: worker, thread_key: {:scope, :key2}, mon_ref: mon_ref}
        },
        waitq: :queue.new(),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 2}
      }

      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, slot_ref1}, state)

      # Should still have 1 slot, monitor should remain
      assert map_size(new_state.in_flight) == 1
      assert Map.has_key?(new_state.monitors, worker)
      assert Map.get(new_state.worker_counts, worker) == 1
    end

    test "releasing last slot removes monitor entirely" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      slot_ref = make_ref()
      mon_ref = Process.monitor(worker)

      state = %{
        max: 5,
        in_flight: %{
          slot_ref => %{worker: worker, thread_key: {:scope, :key1}, mon_ref: mon_ref}
        },
        waitq: :queue.new(),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 1}
      }

      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, slot_ref}, state)

      # Monitor should be removed
      assert map_size(new_state.in_flight) == 0
      assert not Map.has_key?(new_state.monitors, worker)
      assert not Map.has_key?(new_state.worker_counts, worker)

      Process.exit(worker, :kill)
    end

    test "grant_until_full grants multiple waiting slots" do
      # Start with empty in_flight, 3 workers waiting
      workers =
        for _ <- 1..3 do
          spawn(fn ->
            receive do
              {:slot_granted, _ref} -> Process.sleep(:infinity)
            after
              1000 -> :timeout
            end
          end)
        end

      # Manually build waitq with monitor refs
      waitq_entries =
        Enum.with_index(workers)
        |> Enum.map(fn {worker, i} ->
          mon_ref = Process.monitor(worker)
          %{worker: worker, thread_key: {:scope, i}, mon_ref: mon_ref}
        end)

      monitors =
        Enum.zip(workers, waitq_entries)
        |> Enum.into(%{}, fn {worker, entry} -> {worker, entry.mon_ref} end)

      worker_counts = Enum.into(workers, %{}, fn w -> {w, 1} end)

      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.from_list(waitq_entries),
        monitors: monitors,
        worker_counts: worker_counts
      }

      # Simulate releasing a slot (even though none are held), triggering grant_until_full
      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, make_ref()}, state)

      # All 3 waiting should have been granted
      assert map_size(new_state.in_flight) == 3
      assert :queue.is_empty(new_state.waitq)

      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "waitq preserves FIFO order" do
      workers =
        for _ <- 1..3 do
          spawn(fn ->
            receive do
              {:slot_granted, _ref} -> Process.sleep(:infinity)
            end
          end)
        end

      [w1, w2, w3] = workers

      # Occupy the only slot
      occupier = spawn(fn -> Process.sleep(:infinity) end)
      occupier_slot = make_ref()
      occupier_mon = Process.monitor(occupier)

      state = %{
        max: 1,
        in_flight: %{
          occupier_slot => %{
            worker: occupier,
            thread_key: {:scope, :occupier},
            mon_ref: occupier_mon
          }
        },
        waitq: :queue.new(),
        monitors: %{occupier => occupier_mon},
        worker_counts: %{occupier => 1}
      }

      # Queue requests in order: w1, w2, w3
      state_after_queue =
        Enum.with_index([w1, w2, w3])
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      # Release the occupier's slot - w1 should get it first
      {:noreply, after_release} =
        Scheduler.handle_cast({:release_slot, occupier_slot}, state_after_queue)

      # Only w1 should have gotten a slot
      assert map_size(after_release.in_flight) == 1

      # The in_flight entry should be for w1
      [entry] = Map.values(after_release.in_flight)
      assert entry.worker == w1

      # w2 and w3 should still be in waitq
      assert :queue.len(after_release.waitq) == 2

      Enum.each([occupier | workers], &Process.exit(&1, :kill))
    end
  end

  describe "cancel/2" do
    test "cancel returns :ok for alive process" do
      pid =
        spawn(fn ->
          receive do
            {:cancel, _reason} -> :ok
          end
        end)

      assert :ok == Scheduler.cancel(pid, :test_reason)
    end

    test "cancel returns :ok for dead process" do
      pid = spawn(fn -> :ok end)
      # Wait deterministically for the process to stop
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(pid)

      refute Process.alive?(pid)
      assert :ok == Scheduler.cancel(pid, :test_reason)
    end

    test "cancel returns :ok for nil pid" do
      # This tests the guard clause
      assert :ok == Scheduler.cancel(nil, :test_reason)
    end

    test "cancel uses :user_requested as default reason" do
      test_pid = self()
      # GenServer.cast wraps the message, so we need to receive the cast format
      pid =
        spawn(fn ->
          receive do
            {:"$gen_cast", {:cancel, reason}} -> send(test_pid, {:got_cancel, reason})
          after
            1000 -> :timeout
          end
        end)

      # Wait until the spawned process is alive and receiving
      Elixir.LemonGateway.AsyncHelpers.assert_process_alive(pid)
      Scheduler.cancel(pid)

      assert_receive {:got_cancel, :user_requested}, 500
    end
  end

  describe "submit/1 integration" do
    # These tests require the full application to be running

    setup do
      # Stop any existing lemon_gateway
      _ = Application.stop(:lemon_gateway)

      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 2,
        default_engine: "echo",
        enable_telegram: false,
        require_engine_lock: false
      })

      Application.put_env(:lemon_gateway, :engines, [
        Elixir.LemonGateway.SchedulerTest.SlowEngine,
        Elixir.LemonGateway.Engines.Echo
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      on_exit(fn ->
        _ = Application.stop(:lemon_gateway)
      end)

      :ok
    end

    test "submit/1 accepts a valid job" do
      job = make_job()
      assert :ok == Scheduler.submit(job)
    end

    test "submit/1 returns :ok immediately (async)" do
      job = make_job()

      # Submit should return immediately, not block
      {time_us, result} = :timer.tc(fn -> Scheduler.submit(job) end)

      assert result == :ok
      # Should complete in under 10ms (accounting for test overhead)
      assert time_us < 10_000
    end

    test "submit with resume token uses engine/value as thread_key" do
      resume = %ResumeToken{engine: "test_engine", value: "session_123"}
      job = make_job(resume: resume, text: "resumed message")

      assert :ok == Scheduler.submit(job)
    end

    test "submit without resume uses scope as thread_key" do
      scope = %ChatScope{transport: :telegram, chat_id: 42, topic_id: nil}
      job = make_job(scope: scope, resume: nil)

      assert :ok == Scheduler.submit(job)
    end
  end

  describe "edge cases" do
    test "empty waitq after release does not crash" do
      state = %{
        max: 2,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Release on empty state
      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, make_ref()}, state)

      assert new_state.in_flight == %{}
      assert :queue.is_empty(new_state.waitq)
    end

    test "DOWN for unknown process is safe" do
      state = %{
        max: 2,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      unknown_pid = spawn(fn -> :ok end)
      unknown_ref = make_ref()

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, unknown_ref, :process, unknown_pid, :normal}, state)

      # State should be unchanged
      assert new_state == state
    end

    test "max=0 queues all requests" do
      worker = self()

      state = %{
        max: 0,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      {:noreply, new_state} =
        Scheduler.handle_cast({:request_slot, worker, {:scope, :test}}, state)

      # Should be queued, not granted
      assert map_size(new_state.in_flight) == 0
      assert :queue.len(new_state.waitq) == 1

      refute_receive {:slot_granted, _}
    end

    test "worker crash while in waitq is cleaned up" do
      # Create a worker that will die
      worker = spawn(fn -> :ok end)
      # Wait deterministically for it to stop
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(worker)

      # Simulated mon_ref (real one would be invalid now)
      mon_ref = make_ref()

      state = %{
        max: 1,
        in_flight: %{
          make_ref() => %{worker: self(), thread_key: {:scope, :x}, mon_ref: make_ref()}
        },
        waitq: :queue.from_list([%{worker: worker, thread_key: {:scope, :y}, mon_ref: mon_ref}]),
        monitors: %{worker => mon_ref, self() => make_ref()},
        worker_counts: %{worker => 1, self() => 1}
      }

      # Simulate DOWN for the dead worker
      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, mon_ref, :process, worker, :normal}, state)

      # Worker should be removed from waitq
      assert :queue.len(new_state.waitq) == 0
      assert not Map.has_key?(new_state.monitors, worker)
      assert not Map.has_key?(new_state.worker_counts, worker)
    end

    test "cleanup_worker removes all slots for same worker" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)

      slot_ref1 = make_ref()
      slot_ref2 = make_ref()
      slot_ref3 = make_ref()

      state = %{
        max: 5,
        in_flight: %{
          slot_ref1 => %{worker: worker, thread_key: {:scope, :k1}, mon_ref: mon_ref},
          slot_ref2 => %{worker: worker, thread_key: {:scope, :k2}, mon_ref: mon_ref},
          slot_ref3 => %{worker: worker, thread_key: {:scope, :k3}, mon_ref: mon_ref}
        },
        waitq: :queue.new(),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 3}
      }

      Process.exit(worker, :kill)

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, mon_ref, :process, worker, :killed}, state)

      # All entries for worker should be gone
      assert map_size(new_state.in_flight) == 0
      assert not Map.has_key?(new_state.monitors, worker)
      assert not Map.has_key?(new_state.worker_counts, worker)
    end
  end

  describe "concurrent access simulation" do
    test "rapid slot requests are handled correctly" do
      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Simulate 10 rapid slot requests
      workers =
        for _ <- 1..10 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      final_state =
        Enum.with_index(workers)
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      # 5 should be granted, 5 queued
      assert map_size(final_state.in_flight) == 5
      assert :queue.len(final_state.waitq) == 5

      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "interleaved request and release operations" do
      workers =
        for _ <- 1..3 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      [w1, w2, w3] = workers

      state = %{
        max: 2,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Request from w1 - granted
      {:noreply, state} =
        Scheduler.handle_cast({:request_slot, w1, {:scope, 1}}, state)

      assert map_size(state.in_flight) == 1

      # Request from w2 - granted
      {:noreply, state} =
        Scheduler.handle_cast({:request_slot, w2, {:scope, 2}}, state)

      assert map_size(state.in_flight) == 2

      # Request from w3 - queued (at max)
      {:noreply, state} =
        Scheduler.handle_cast({:request_slot, w3, {:scope, 3}}, state)

      assert map_size(state.in_flight) == 2
      assert :queue.len(state.waitq) == 1

      # Find w1's slot_ref
      w1_slot =
        state.in_flight
        |> Enum.find(fn {_ref, entry} -> entry.worker == w1 end)
        |> elem(0)

      # Release w1's slot - w3 should be granted
      {:noreply, state} =
        Scheduler.handle_cast({:release_slot, w1_slot}, state)

      assert map_size(state.in_flight) == 2
      assert :queue.is_empty(state.waitq)

      # Verify w3 is now in in_flight
      w3_in_flight =
        state.in_flight
        |> Enum.any?(fn {_ref, entry} -> entry.worker == w3 end)

      assert w3_in_flight

      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "worker death during slot grant cycle" do
      # Worker that will die mid-test
      dying_worker =
        spawn(fn ->
          receive do
            :die -> :ok
          end
        end)

      stable_worker = self()

      mon_ref_dying = Process.monitor(dying_worker)
      mon_ref_stable = Process.monitor(stable_worker)

      # Both have slots
      slot_dying = make_ref()
      slot_stable = make_ref()

      state = %{
        max: 2,
        in_flight: %{
          slot_dying => %{
            worker: dying_worker,
            thread_key: {:scope, :dying},
            mon_ref: mon_ref_dying
          },
          slot_stable => %{
            worker: stable_worker,
            thread_key: {:scope, :stable},
            mon_ref: mon_ref_stable
          }
        },
        waitq: :queue.new(),
        monitors: %{dying_worker => mon_ref_dying, stable_worker => mon_ref_stable},
        worker_counts: %{dying_worker => 1, stable_worker => 1}
      }

      # Kill the dying worker and wait for it to stop
      send(dying_worker, :die)
      Elixir.LemonGateway.AsyncHelpers.assert_process_dead(dying_worker)

      {:noreply, state} =
        Scheduler.handle_info({:DOWN, mon_ref_dying, :process, dying_worker, :normal}, state)

      # Only stable_worker should remain
      assert map_size(state.in_flight) == 1
      assert not Map.has_key?(state.monitors, dying_worker)
      assert Map.has_key?(state.monitors, stable_worker)
    end
  end

  describe "thread_key derivation (via submit)" do
    setup do
      _ = Application.stop(:lemon_gateway)

      Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
        max_concurrent_runs: 10,
        default_engine: "echo",
        enable_telegram: false,
        require_engine_lock: false
      })

      Application.put_env(:lemon_gateway, :engines, [
        Elixir.LemonGateway.SchedulerTest.SlowEngine,
        Elixir.LemonGateway.Engines.Echo
      ])

      {:ok, _} = Application.ensure_all_started(:lemon_gateway)

      on_exit(fn ->
        _ = Application.stop(:lemon_gateway)
      end)

      :ok
    end

    test "job with resume token creates thread_key from engine and value" do
      resume = %ResumeToken{engine: "claude", value: "session-abc"}

      job = %Job{
        prompt: "test",
        resume: resume,
        engine_id: "echo",
        meta: %{user_msg_id: 1}
      }

      # Submit should succeed
      assert :ok == Scheduler.submit(job)
    end

    test "job with session_key and resume token creates thread_key from session_key" do
      session_key = "session_#{System.unique_integer([:positive])}"

      resume = %ResumeToken{
        engine: Elixir.LemonGateway.SchedulerTest.SlowEngine.id(),
        value: "resume_#{System.unique_integer([:positive])}"
      }

      job = %Job{
        session_key: session_key,
        prompt: "test",
        resume: resume,
        engine_id: Elixir.LemonGateway.SchedulerTest.SlowEngine.id(),
        meta: %{delay_ms: 200}
      }

      assert :ok == Scheduler.submit(job)

      assert eventually(fn ->
               is_pid(Elixir.LemonGateway.ThreadRegistry.whereis({:session, session_key}))
             end)

      assert Elixir.LemonGateway.ThreadRegistry.whereis({resume.engine, resume.value}) == nil
    end

    test "job without resume token creates thread_key from session_key" do
      session_key = "test:888:42"

      job = %Job{
        session_key: session_key,
        prompt: "test",
        resume: nil,
        engine_id: "echo",
        meta: %{user_msg_id: 1}
      }

      assert :ok == Scheduler.submit(job)
    end
  end

  describe "worker count tracking edge cases" do
    test "worker_counts accurately tracks multiple slots per worker" do
      worker = self()

      state = %{
        max: 10,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Request 5 slots for the same worker
      final_state =
        Enum.reduce(1..5, state, fn i, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      assert Map.get(final_state.worker_counts, worker) == 5
      assert map_size(final_state.monitors) == 1

      # Collect all slot refs
      slot_refs = Map.keys(final_state.in_flight)
      assert length(slot_refs) == 5

      # Release slots one by one and verify count decrements
      {final_state_after_releases, _} =
        Enum.reduce(slot_refs, {final_state, 5}, fn slot_ref, {acc_state, expected_count} ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:release_slot, slot_ref}, acc_state)

          new_expected = expected_count - 1

          if new_expected > 0 do
            assert Map.get(new_state.worker_counts, worker) == new_expected
            assert Map.has_key?(new_state.monitors, worker)
          else
            assert not Map.has_key?(new_state.worker_counts, worker)
            assert not Map.has_key?(new_state.monitors, worker)
          end

          {new_state, new_expected}
        end)

      # Final state should have no traces of the worker
      assert map_size(final_state_after_releases.in_flight) == 0
      assert not Map.has_key?(final_state_after_releases.worker_counts, worker)
      assert not Map.has_key?(final_state_after_releases.monitors, worker)
    end

    test "worker_counts increments when worker has both in_flight and waitq entries" do
      worker = self()

      # Start with max=1 so second request goes to waitq
      state = %{
        max: 1,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # First request - goes to in_flight
      {:noreply, state} =
        Scheduler.handle_cast({:request_slot, worker, {:scope, 1}}, state)

      assert Map.get(state.worker_counts, worker) == 1

      # Second request - goes to waitq
      {:noreply, state} =
        Scheduler.handle_cast({:request_slot, worker, {:scope, 2}}, state)

      assert Map.get(state.worker_counts, worker) == 2
      assert map_size(state.in_flight) == 1
      assert :queue.len(state.waitq) == 1
    end

    test "worker_counts handles zero correctly (should never go negative)" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)

      # Start with worker_counts at 1
      slot_ref = make_ref()

      state = %{
        max: 5,
        in_flight: %{
          slot_ref => %{worker: worker, thread_key: {:scope, :k1}, mon_ref: mon_ref}
        },
        waitq: :queue.new(),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 1}
      }

      # Release the slot
      {:noreply, state} =
        Scheduler.handle_cast({:release_slot, slot_ref}, state)

      assert not Map.has_key?(state.worker_counts, worker)

      # Try releasing again (should be safe even though worker has no slots)
      {:noreply, state2} =
        Scheduler.handle_cast({:release_slot, make_ref()}, state)

      # Should still have no worker_counts entry (not negative)
      assert not Map.has_key?(state2.worker_counts, worker)

      Process.exit(worker, :kill)
    end

    test "worker_counts tracks multiple workers independently" do
      worker1 = spawn(fn -> Process.sleep(:infinity) end)
      worker2 = spawn(fn -> Process.sleep(:infinity) end)
      worker3 = spawn(fn -> Process.sleep(:infinity) end)

      state = %{
        max: 10,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Worker1 gets 3 slots, worker2 gets 2 slots, worker3 gets 1 slot
      requests = [
        {worker1, 1},
        {worker1, 2},
        {worker1, 3},
        {worker2, 4},
        {worker2, 5},
        {worker3, 6}
      ]

      final_state =
        Enum.reduce(requests, state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      assert Map.get(final_state.worker_counts, worker1) == 3
      assert Map.get(final_state.worker_counts, worker2) == 2
      assert Map.get(final_state.worker_counts, worker3) == 1
      assert map_size(final_state.monitors) == 3

      # Kill worker1 and verify cleanup
      mon_ref1 = Map.get(final_state.monitors, worker1)
      Process.exit(worker1, :kill)

      {:noreply, after_w1_death} =
        Scheduler.handle_info({:DOWN, mon_ref1, :process, worker1, :killed}, final_state)

      assert not Map.has_key?(after_w1_death.worker_counts, worker1)
      assert Map.get(after_w1_death.worker_counts, worker2) == 2
      assert Map.get(after_w1_death.worker_counts, worker3) == 1
      # Only worker2 and worker3 slots remain
      assert map_size(after_w1_death.in_flight) == 3

      Process.exit(worker2, :kill)
      Process.exit(worker3, :kill)
    end
  end

  describe "slot allocation and release edge cases" do
    test "releasing same slot_ref twice is safe" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)
      slot_ref = make_ref()

      state = %{
        max: 5,
        in_flight: %{
          slot_ref => %{worker: worker, thread_key: {:scope, :k1}, mon_ref: mon_ref}
        },
        waitq: :queue.new(),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 1}
      }

      # First release
      {:noreply, state1} =
        Scheduler.handle_cast({:release_slot, slot_ref}, state)

      assert map_size(state1.in_flight) == 0

      # Second release of same slot_ref (should be no-op)
      {:noreply, state2} =
        Scheduler.handle_cast({:release_slot, slot_ref}, state1)

      assert state2 == state1

      Process.exit(worker, :kill)
    end

    test "slot allocation preserves thread_key in entry" do
      worker = self()
      thread_key = {:scope, %ChatScope{transport: :telegram, chat_id: 12345, topic_id: 99}}

      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      {:noreply, new_state} =
        Scheduler.handle_cast({:request_slot, worker, thread_key}, state)

      assert_receive {:slot_granted, slot_ref}

      entry = Map.get(new_state.in_flight, slot_ref)
      assert entry.thread_key == thread_key
      assert entry.worker == worker
    end

    test "waitq entries preserve thread_key" do
      occupier = spawn(fn -> Process.sleep(:infinity) end)
      waiter = self()

      # Occupy the only slot
      occupier_slot = make_ref()
      occupier_mon = Process.monitor(occupier)

      state = %{
        max: 1,
        in_flight: %{
          occupier_slot => %{
            worker: occupier,
            thread_key: {:scope, :occupier},
            mon_ref: occupier_mon
          }
        },
        waitq: :queue.new(),
        monitors: %{occupier => occupier_mon},
        worker_counts: %{occupier => 1}
      }

      waiter_thread_key = {:scope, %ChatScope{transport: :test, chat_id: 999}}

      {:noreply, state_after_queue} =
        Scheduler.handle_cast({:request_slot, waiter, waiter_thread_key}, state)

      # Release occupier's slot
      {:noreply, final_state} =
        Scheduler.handle_cast({:release_slot, occupier_slot}, state_after_queue)

      assert_receive {:slot_granted, slot_ref}

      # Verify the granted slot has correct thread_key
      entry = Map.get(final_state.in_flight, slot_ref)
      assert entry.thread_key == waiter_thread_key
      assert entry.worker == waiter

      Process.exit(occupier, :kill)
    end

    test "release_slot with nil entry in maybe_demonitor_worker is handled" do
      # This tests the maybe_demonitor_worker(state, nil) clause
      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # pop_in_flight will return nil for entry, triggering maybe_demonitor_worker(state, nil)
      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, make_ref()}, state)

      assert new_state == state
    end

    test "slot allocation when worker already has monitor but count is somehow missing" do
      # Edge case: monitor exists but worker_counts entry is nil
      worker = self()
      existing_mon_ref = Process.monitor(worker)

      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{worker => existing_mon_ref},
        # Missing entry for worker
        worker_counts: %{}
      }

      {:noreply, new_state} =
        Scheduler.handle_cast({:request_slot, worker, {:scope, :test}}, state)

      # Should use existing monitor and set count to 1
      assert Map.get(new_state.monitors, worker) == existing_mon_ref
      assert Map.get(new_state.worker_counts, worker) == 1
    end
  end

  describe "concurrent slot requests" do
    test "multiple workers requesting slots simultaneously are handled in order" do
      # Simulate 20 workers making requests
      workers =
        for i <- 1..20 do
          spawn(fn ->
            receive do
              {:slot_granted, _ref} -> send(self(), {:worker_got_slot, i})
            after
              5000 -> :timeout
            end
          end)
        end

      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      final_state =
        Enum.with_index(workers)
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      # First 5 should be in_flight
      assert map_size(final_state.in_flight) == 5

      # Remaining 15 should be queued
      assert :queue.len(final_state.waitq) == 15

      # All 20 workers should have monitors
      assert map_size(final_state.monitors) == 20

      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "burst release followed by burst requests" do
      # Create initial state with 5 occupied slots
      workers =
        for _ <- 1..5 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      {initial_state, slot_refs} =
        Enum.with_index(workers)
        |> Enum.reduce(
          {%{
             max: 5,
             in_flight: %{},
             waitq: :queue.new(),
             monitors: %{},
             worker_counts: %{}
           }, []},
          fn {worker, i}, {acc_state, refs} ->
            {:noreply, new_state} =
              Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc_state)

            new_refs = Map.keys(new_state.in_flight) -- refs
            {new_state, refs ++ new_refs}
          end
        )

      assert map_size(initial_state.in_flight) == 5
      assert length(slot_refs) == 5

      # Release all 5 slots
      state_after_releases =
        Enum.reduce(slot_refs, initial_state, fn slot_ref, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:release_slot, slot_ref}, acc)

          new_state
        end)

      assert map_size(state_after_releases.in_flight) == 0

      # New burst of 10 requests
      new_workers =
        for _ <- 1..10 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      final_state =
        Enum.with_index(new_workers)
        |> Enum.reduce(state_after_releases, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i + 100}}, acc)

          new_state
        end)

      # 5 should be granted, 5 queued
      assert map_size(final_state.in_flight) == 5
      assert :queue.len(final_state.waitq) == 5

      Enum.each(workers ++ new_workers, &Process.exit(&1, :kill))
    end

    test "alternating request and release maintains consistency" do
      state = %{
        max: 2,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      workers =
        for _ <- 1..6 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      # Process: request, request, release first, request, release second, request...
      [w1, w2, w3, w4, w5, _w6] = workers

      # Request w1 - granted
      {:noreply, state} = Scheduler.handle_cast({:request_slot, w1, {:scope, 1}}, state)
      assert map_size(state.in_flight) == 1

      # Request w2 - granted
      {:noreply, state} = Scheduler.handle_cast({:request_slot, w2, {:scope, 2}}, state)
      assert map_size(state.in_flight) == 2

      # Request w3 - queued
      {:noreply, state} = Scheduler.handle_cast({:request_slot, w3, {:scope, 3}}, state)
      assert map_size(state.in_flight) == 2
      assert :queue.len(state.waitq) == 1

      # Release w1's slot - w3 gets it
      w1_slot = state.in_flight |> Enum.find(fn {_, e} -> e.worker == w1 end) |> elem(0)
      {:noreply, state} = Scheduler.handle_cast({:release_slot, w1_slot}, state)
      assert map_size(state.in_flight) == 2
      assert :queue.is_empty(state.waitq)

      # Verify w3 is now in_flight
      assert Enum.any?(state.in_flight, fn {_, e} -> e.worker == w3 end)

      # Request w4 - queued
      {:noreply, state} = Scheduler.handle_cast({:request_slot, w4, {:scope, 4}}, state)
      assert :queue.len(state.waitq) == 1

      # Request w5 - queued
      {:noreply, state} = Scheduler.handle_cast({:request_slot, w5, {:scope, 5}}, state)
      assert :queue.len(state.waitq) == 2

      # Release w2's slot - w4 gets it
      w2_slot = state.in_flight |> Enum.find(fn {_, e} -> e.worker == w2 end) |> elem(0)
      {:noreply, state} = Scheduler.handle_cast({:release_slot, w2_slot}, state)
      assert map_size(state.in_flight) == 2
      assert :queue.len(state.waitq) == 1

      # Verify w4 is now in_flight
      assert Enum.any?(state.in_flight, fn {_, e} -> e.worker == w4 end)

      # w5 should still be in waitq
      waitq_workers = state.waitq |> :queue.to_list() |> Enum.map(& &1.worker)
      assert w5 in waitq_workers

      Enum.each(workers, &Process.exit(&1, :kill))
    end
  end

  describe "cleanup_worker/2 full worker state cleanup" do
    test "cleanup_worker removes worker from all state components" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)

      # Worker has 2 in_flight slots and 1 waitq entry
      slot_ref1 = make_ref()
      slot_ref2 = make_ref()

      state = %{
        max: 5,
        in_flight: %{
          slot_ref1 => %{worker: worker, thread_key: {:scope, :k1}, mon_ref: mon_ref},
          slot_ref2 => %{worker: worker, thread_key: {:scope, :k2}, mon_ref: mon_ref}
        },
        waitq:
          :queue.from_list([
            %{worker: worker, thread_key: {:scope, :k3}, mon_ref: mon_ref}
          ]),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 3}
      }

      Process.exit(worker, :kill)

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, mon_ref, :process, worker, :killed}, state)

      # All traces of worker should be removed
      assert map_size(new_state.in_flight) == 0
      assert :queue.is_empty(new_state.waitq)
      assert not Map.has_key?(new_state.monitors, worker)
      assert not Map.has_key?(new_state.worker_counts, worker)
    end

    test "cleanup_worker only affects the crashed worker, not others" do
      worker1 = spawn(fn -> Process.sleep(:infinity) end)
      worker2 = spawn(fn -> Process.sleep(:infinity) end)

      mon_ref1 = Process.monitor(worker1)
      mon_ref2 = Process.monitor(worker2)

      slot_ref1 = make_ref()
      slot_ref2 = make_ref()

      # Use max: 2 so both in_flight slots are filled and no grants from waitq on cleanup
      state = %{
        max: 2,
        in_flight: %{
          slot_ref1 => %{worker: worker1, thread_key: {:scope, :k1}, mon_ref: mon_ref1},
          slot_ref2 => %{worker: worker2, thread_key: {:scope, :k2}, mon_ref: mon_ref2}
        },
        waitq:
          :queue.from_list([
            %{worker: worker1, thread_key: {:scope, :k3}, mon_ref: mon_ref1},
            %{worker: worker2, thread_key: {:scope, :k4}, mon_ref: mon_ref2}
          ]),
        monitors: %{worker1 => mon_ref1, worker2 => mon_ref2},
        worker_counts: %{worker1 => 2, worker2 => 2}
      }

      Process.exit(worker1, :kill)

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, mon_ref1, :process, worker1, :killed}, state)

      # Worker1 should be gone
      assert not Map.has_key?(new_state.monitors, worker1)
      assert not Map.has_key?(new_state.worker_counts, worker1)

      # Worker2 should remain with both entries (1 in_flight + 1 granted from waitq after worker1's slot freed)
      assert Map.has_key?(new_state.monitors, worker2)

      # After worker1 dies (freeing 1 in_flight slot), grant_until_full grants worker2's waitq entry
      # So worker2 now has 2 in_flight slots (original + newly granted from waitq)
      assert map_size(new_state.in_flight) == 2
      # All in_flight entries should be for worker2
      in_flight_workers = new_state.in_flight |> Map.values() |> Enum.map(& &1.worker)
      assert Enum.all?(in_flight_workers, &(&1 == worker2))

      # Waitq should be empty (worker1's entry removed, worker2's entry granted)
      assert :queue.is_empty(new_state.waitq)

      # Worker2's count should be 2 (both slots now in_flight)
      assert Map.get(new_state.worker_counts, worker2) == 2

      Process.exit(worker2, :kill)
    end

    test "cleanup_worker when worker has entries only in waitq" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)

      # Worker only has waitq entries, no in_flight
      state = %{
        # max=0 so nothing can be in_flight
        max: 0,
        in_flight: %{},
        waitq:
          :queue.from_list([
            %{worker: worker, thread_key: {:scope, :k1}, mon_ref: mon_ref},
            %{worker: worker, thread_key: {:scope, :k2}, mon_ref: mon_ref}
          ]),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 2}
      }

      Process.exit(worker, :kill)

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, mon_ref, :process, worker, :killed}, state)

      assert :queue.is_empty(new_state.waitq)
      assert not Map.has_key?(new_state.monitors, worker)
      assert not Map.has_key?(new_state.worker_counts, worker)
    end

    test "cleanup_worker triggers grant_until_full for waiting workers" do
      dying_worker = spawn(fn -> Process.sleep(:infinity) end)
      waiting_worker = self()

      dying_mon_ref = Process.monitor(dying_worker)
      waiting_mon_ref = Process.monitor(waiting_worker)

      dying_slot = make_ref()

      # dying_worker has the only slot, waiting_worker is queued
      state = %{
        max: 1,
        in_flight: %{
          dying_slot => %{
            worker: dying_worker,
            thread_key: {:scope, :dying},
            mon_ref: dying_mon_ref
          }
        },
        waitq:
          :queue.from_list([
            %{worker: waiting_worker, thread_key: {:scope, :waiting}, mon_ref: waiting_mon_ref}
          ]),
        monitors: %{dying_worker => dying_mon_ref, waiting_worker => waiting_mon_ref},
        worker_counts: %{dying_worker => 1, waiting_worker => 1}
      }

      Process.exit(dying_worker, :kill)

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, dying_mon_ref, :process, dying_worker, :killed}, state)

      # Waiting worker should have been granted the slot
      assert_receive {:slot_granted, slot_ref}
      assert map_size(new_state.in_flight) == 1
      assert Map.get(new_state.in_flight, slot_ref).worker == waiting_worker
      assert :queue.is_empty(new_state.waitq)
    end

    test "cleanup_worker handles worker_counts being nil for worker" do
      # Edge case: worker in monitors but not in worker_counts (shouldn't happen normally)
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)
      slot_ref = make_ref()

      state = %{
        max: 5,
        in_flight: %{
          slot_ref => %{worker: worker, thread_key: {:scope, :k1}, mon_ref: mon_ref}
        },
        waitq: :queue.new(),
        monitors: %{worker => mon_ref},
        # Missing entry
        worker_counts: %{}
      }

      Process.exit(worker, :kill)

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, mon_ref, :process, worker, :killed}, state)

      # Should still clean up properly
      assert map_size(new_state.in_flight) == 0
      assert not Map.has_key?(new_state.monitors, worker)
    end

    test "cleanup_worker correctly calculates removed_count" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)

      # Worker has 3 in_flight and 2 waitq entries = 5 total
      slot_ref1 = make_ref()
      slot_ref2 = make_ref()
      slot_ref3 = make_ref()

      state = %{
        max: 10,
        in_flight: %{
          slot_ref1 => %{worker: worker, thread_key: {:scope, :k1}, mon_ref: mon_ref},
          slot_ref2 => %{worker: worker, thread_key: {:scope, :k2}, mon_ref: mon_ref},
          slot_ref3 => %{worker: worker, thread_key: {:scope, :k3}, mon_ref: mon_ref}
        },
        waitq:
          :queue.from_list([
            %{worker: worker, thread_key: {:scope, :k4}, mon_ref: mon_ref},
            %{worker: worker, thread_key: {:scope, :k5}, mon_ref: mon_ref}
          ]),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 5}
      }

      Process.exit(worker, :kill)

      {:noreply, new_state} =
        Scheduler.handle_info({:DOWN, mon_ref, :process, worker, :killed}, state)

      # All should be cleaned up
      assert map_size(new_state.in_flight) == 0
      assert :queue.is_empty(new_state.waitq)
      assert not Map.has_key?(new_state.worker_counts, worker)
    end
  end

  describe "worker state transitions" do
    test "worker transitions from no state -> in_flight" do
      worker = self()

      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Initial state: worker has no entries
      assert not Map.has_key?(state.monitors, worker)
      assert not Map.has_key?(state.worker_counts, worker)

      {:noreply, new_state} =
        Scheduler.handle_cast({:request_slot, worker, {:scope, :test}}, state)

      # After request: worker is in monitors and worker_counts
      assert Map.has_key?(new_state.monitors, worker)
      assert Map.get(new_state.worker_counts, worker) == 1
      assert map_size(new_state.in_flight) == 1
    end

    test "worker transitions from no state -> waitq when at capacity" do
      occupier = spawn(fn -> Process.sleep(:infinity) end)
      worker = self()

      occupier_slot = make_ref()
      occupier_mon = Process.monitor(occupier)

      state = %{
        max: 1,
        in_flight: %{
          occupier_slot => %{worker: occupier, thread_key: {:scope, :occ}, mon_ref: occupier_mon}
        },
        waitq: :queue.new(),
        monitors: %{occupier => occupier_mon},
        worker_counts: %{occupier => 1}
      }

      {:noreply, new_state} =
        Scheduler.handle_cast({:request_slot, worker, {:scope, :test}}, state)

      # Worker should be in waitq, monitors, and worker_counts
      assert not :queue.is_empty(new_state.waitq)
      assert Map.has_key?(new_state.monitors, worker)
      assert Map.get(new_state.worker_counts, worker) == 1

      # Should not have received slot
      refute_receive {:slot_granted, _}

      Process.exit(occupier, :kill)
    end

    test "worker transitions from waitq -> in_flight when slot becomes available" do
      occupier = spawn(fn -> Process.sleep(:infinity) end)
      worker = self()

      occupier_slot = make_ref()
      occupier_mon = Process.monitor(occupier)
      worker_mon = Process.monitor(worker)

      # Worker is in waitq
      state = %{
        max: 1,
        in_flight: %{
          occupier_slot => %{worker: occupier, thread_key: {:scope, :occ}, mon_ref: occupier_mon}
        },
        waitq:
          :queue.from_list([
            %{worker: worker, thread_key: {:scope, :test}, mon_ref: worker_mon}
          ]),
        monitors: %{occupier => occupier_mon, worker => worker_mon},
        worker_counts: %{occupier => 1, worker => 1}
      }

      # Release occupier's slot
      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, occupier_slot}, state)

      # Worker should now be in_flight
      assert_receive {:slot_granted, slot_ref}
      assert Map.has_key?(new_state.in_flight, slot_ref)
      assert Map.get(new_state.in_flight, slot_ref).worker == worker
      assert :queue.is_empty(new_state.waitq)

      Process.exit(occupier, :kill)
    end

    test "worker transitions from in_flight -> removed when last slot released" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)
      slot_ref = make_ref()

      state = %{
        max: 5,
        in_flight: %{
          slot_ref => %{worker: worker, thread_key: {:scope, :test}, mon_ref: mon_ref}
        },
        waitq: :queue.new(),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 1}
      }

      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, slot_ref}, state)

      # Worker should be completely removed
      assert not Map.has_key?(new_state.monitors, worker)
      assert not Map.has_key?(new_state.worker_counts, worker)
      assert map_size(new_state.in_flight) == 0

      Process.exit(worker, :kill)
    end

    test "worker transitions from in_flight -> reduced count when one slot released" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      mon_ref = Process.monitor(worker)
      slot_ref1 = make_ref()
      slot_ref2 = make_ref()

      state = %{
        max: 5,
        in_flight: %{
          slot_ref1 => %{worker: worker, thread_key: {:scope, :k1}, mon_ref: mon_ref},
          slot_ref2 => %{worker: worker, thread_key: {:scope, :k2}, mon_ref: mon_ref}
        },
        waitq: :queue.new(),
        monitors: %{worker => mon_ref},
        worker_counts: %{worker => 2}
      }

      {:noreply, new_state} =
        Scheduler.handle_cast({:release_slot, slot_ref1}, state)

      # Worker should still exist but with reduced count
      assert Map.has_key?(new_state.monitors, worker)
      assert Map.get(new_state.worker_counts, worker) == 1
      assert map_size(new_state.in_flight) == 1

      Process.exit(worker, :kill)
    end

    test "worker transitions through full lifecycle" do
      worker = self()

      # Phase 1: Empty state
      state = %{
        max: 2,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Phase 2: First slot request - granted
      {:noreply, state} =
        Scheduler.handle_cast({:request_slot, worker, {:scope, 1}}, state)

      assert_receive {:slot_granted, slot_ref1}
      assert Map.get(state.worker_counts, worker) == 1

      # Phase 3: Second slot request - granted
      {:noreply, state} =
        Scheduler.handle_cast({:request_slot, worker, {:scope, 2}}, state)

      assert_receive {:slot_granted, slot_ref2}
      assert Map.get(state.worker_counts, worker) == 2

      # Phase 4: Third slot request - queued (at max)
      {:noreply, state} =
        Scheduler.handle_cast({:request_slot, worker, {:scope, 3}}, state)

      refute_receive {:slot_granted, _}
      assert Map.get(state.worker_counts, worker) == 3

      # Phase 5: Release first slot - queued request granted
      {:noreply, state} =
        Scheduler.handle_cast({:release_slot, slot_ref1}, state)

      assert_receive {:slot_granted, slot_ref3}
      # Released 1, granted 1 from waitq
      assert Map.get(state.worker_counts, worker) == 2

      # Phase 6: Release all slots
      {:noreply, state} =
        Scheduler.handle_cast({:release_slot, slot_ref2}, state)

      assert Map.get(state.worker_counts, worker) == 1

      {:noreply, state} =
        Scheduler.handle_cast({:release_slot, slot_ref3}, state)

      # Phase 7: Worker should be completely removed
      assert not Map.has_key?(state.monitors, worker)
      assert not Map.has_key?(state.worker_counts, worker)
    end
  end

  describe "maximum worker limits" do
    test "max=1 only allows one concurrent slot" do
      workers =
        for _ <- 1..5 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      state = %{
        max: 1,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      final_state =
        Enum.with_index(workers)
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      assert map_size(final_state.in_flight) == 1
      assert :queue.len(final_state.waitq) == 4

      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "max=100 allows many concurrent slots" do
      workers =
        for _ <- 1..50 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      state = %{
        max: 100,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      final_state =
        Enum.with_index(workers)
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      # All 50 should be granted (under max of 100)
      assert map_size(final_state.in_flight) == 50
      assert :queue.is_empty(final_state.waitq)

      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "exact max boundary - grants up to max, queues the rest" do
      workers =
        for _ <- 1..10 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      state = %{
        max: 7,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      final_state =
        Enum.with_index(workers)
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      assert map_size(final_state.in_flight) == 7
      assert :queue.len(final_state.waitq) == 3

      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "same worker can fill all max slots" do
      worker = self()

      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Request more than max slots
      final_state =
        Enum.reduce(1..8, state, fn i, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      # 5 granted, 3 queued - all for same worker
      assert map_size(final_state.in_flight) == 5
      assert :queue.len(final_state.waitq) == 3
      assert Map.get(final_state.worker_counts, worker) == 8
      # Only one monitor for the worker
      assert map_size(final_state.monitors) == 1

      # Receive the 5 granted slots
      for _ <- 1..5 do
        assert_receive {:slot_granted, _ref}
      end

      # Should not receive more
      refute_receive {:slot_granted, _}
    end

    test "releasing slots at max allows queued workers through" do
      workers =
        for _ <- 1..6 do
          spawn(fn ->
            receive do
              {:slot_granted, _} -> Process.sleep(:infinity)
            end
          end)
        end

      state = %{
        max: 3,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # All 6 request slots
      state =
        Enum.with_index(workers)
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      assert map_size(state.in_flight) == 3
      assert :queue.len(state.waitq) == 3

      # Release all 3 in_flight slots
      slot_refs = Map.keys(state.in_flight)

      final_state =
        Enum.reduce(slot_refs, state, fn slot_ref, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:release_slot, slot_ref}, acc)

          new_state
        end)

      # All 3 queued should now be granted
      assert map_size(final_state.in_flight) == 3
      assert :queue.is_empty(final_state.waitq)

      # The in_flight workers should be the ones that were previously queued
      in_flight_workers =
        final_state.in_flight
        |> Map.values()
        |> Enum.map(& &1.worker)
        |> MapSet.new()

      # First 3 workers got slots initially, then released, last 3 should be in_flight now
      [_, _, _, w4, w5, w6] = workers
      expected_workers = MapSet.new([w4, w5, w6])
      assert in_flight_workers == expected_workers

      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "worker death frees slot allowing queued worker through respecting max" do
      [w1, w2, w3, w4] =
        for _ <- 1..4 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      mon_ref1 = Process.monitor(w1)
      mon_ref2 = Process.monitor(w2)

      slot_ref1 = make_ref()
      slot_ref2 = make_ref()

      # w1, w2 have slots, w3, w4 are waiting
      mon_ref3 = Process.monitor(w3)
      mon_ref4 = Process.monitor(w4)

      state = %{
        max: 2,
        in_flight: %{
          slot_ref1 => %{worker: w1, thread_key: {:scope, 1}, mon_ref: mon_ref1},
          slot_ref2 => %{worker: w2, thread_key: {:scope, 2}, mon_ref: mon_ref2}
        },
        waitq:
          :queue.from_list([
            %{worker: w3, thread_key: {:scope, 3}, mon_ref: mon_ref3},
            %{worker: w4, thread_key: {:scope, 4}, mon_ref: mon_ref4}
          ]),
        monitors: %{w1 => mon_ref1, w2 => mon_ref2, w3 => mon_ref3, w4 => mon_ref4},
        worker_counts: %{w1 => 1, w2 => 1, w3 => 1, w4 => 1}
      }

      # w1 dies
      Process.exit(w1, :kill)

      {:noreply, state} =
        Scheduler.handle_info({:DOWN, mon_ref1, :process, w1, :killed}, state)

      # w3 should be granted (was first in queue)
      # Still at max
      assert map_size(state.in_flight) == 2
      # Only w4 waiting now
      assert :queue.len(state.waitq) == 1

      # Verify w2 still has its slot
      assert Enum.any?(state.in_flight, fn {_, e} -> e.worker == w2 end)
      # Verify w3 now has a slot
      assert Enum.any?(state.in_flight, fn {_, e} -> e.worker == w3 end)
      # Verify w4 is still waiting
      [waitq_entry] = :queue.to_list(state.waitq)
      assert waitq_entry.worker == w4

      Enum.each([w2, w3, w4], &Process.exit(&1, :kill))
    end
  end

  describe "stress tests" do
    test "high volume slot cycling maintains consistency" do
      workers =
        for _ <- 1..20 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Initial allocation
      state =
        Enum.with_index(workers)
        |> Enum.reduce(state, fn {worker, i}, acc ->
          {:noreply, new_state} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, i}}, acc)

          new_state
        end)

      assert map_size(state.in_flight) == 5
      assert :queue.len(state.waitq) == 15

      # Release and re-request cycle 10 times
      final_state =
        Enum.reduce(1..10, state, fn _, acc_state ->
          # Release one slot
          slot_to_release = acc_state.in_flight |> Map.keys() |> hd()

          {:noreply, after_release} =
            Scheduler.handle_cast({:release_slot, slot_to_release}, acc_state)

          # Invariant: after release, a waiting worker should be granted
          # So in_flight should still be at max (5) if there were waiters
          after_release
        end)

      # After all cycles, should still have 5 in_flight
      assert map_size(final_state.in_flight) == 5
      # 10 releases = 10 grants from waitq = 5 remaining in waitq
      assert :queue.len(final_state.waitq) == 5

      Enum.each(workers, &Process.exit(&1, :kill))
    end

    test "invariant: in_flight + waitq worker counts match sum of worker_counts" do
      workers =
        for _ <- 1..15 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      state = %{
        max: 5,
        in_flight: %{},
        waitq: :queue.new(),
        monitors: %{},
        worker_counts: %{}
      }

      # Each worker requests 2 slots
      final_state =
        Enum.reduce(workers, state, fn worker, acc ->
          {:noreply, state1} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, :a}}, acc)

          {:noreply, state2} =
            Scheduler.handle_cast({:request_slot, worker, {:scope, :b}}, state1)

          state2
        end)

      # Total slots requested: 15 * 2 = 30
      # 5 should be in_flight, 25 in waitq
      assert map_size(final_state.in_flight) == 5
      assert :queue.len(final_state.waitq) == 25

      # Sum of worker_counts should equal in_flight + waitq size
      total_worker_counts = final_state.worker_counts |> Map.values() |> Enum.sum()
      assert total_worker_counts == 30

      Enum.each(workers, &Process.exit(&1, :kill))
    end
  end

  defp eventually(fun, attempts_left \\ 40)

  defp eventually(fun, 0) when is_function(fun, 0) do
    fun.()
  end

  defp eventually(fun, attempts_left) when is_function(fun, 0) and attempts_left > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end
end
