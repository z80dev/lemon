defmodule LemonGateway.ThreadWorkerTest do
  use ExUnit.Case, async: false

  alias LemonGateway.{ExecutionRequest, Scheduler, ThreadWorker}
  alias LemonCore.ResumeToken

  defmodule SelectiveFailingRunSupervisor do
    alias LemonGateway.ExecutionRequest

    def start_run(%{execution_request: %ExecutionRequest{prompt: "malformed"} = request}) do
      if pid = :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        send(pid, {:run_start_attempt, request.run_id})
      end

      {:error, :malformed_request}
    end

    def start_run(args), do: LemonGateway.RunSupervisor.start_run(args)
  end

  defmodule ControlledExecutor do
    @behaviour LemonGateway.Executor

    alias LemonGateway.Event
    alias LemonGateway.ExecutionRequest

    @impl true
    def start_run(%ExecutionRequest{} = request, _opts, sink_pid) do
      run_ref = make_ref()
      resume = request.resume || %ResumeToken{engine: "lemon", value: unique_id()}

      send(
        sink_pid,
        {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})}
      )

      send(request.meta.notify_pid, {:executor_started, request, sink_pid, run_ref})
      {:ok, run_ref, %{}}
    end

    @impl true
    def cancel(_context), do: :ok

    @impl true
    def steer(_context, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_context, _text), do: {:error, :unsupported}

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  defmodule ControlledRunSupervisor do
    def start_run(%{execution_request: request, worker_pid: worker, slot_ref: slot_ref}) do
      owner = request.meta.notify_pid

      pid =
        spawn(fn ->
          monitor = Process.monitor(worker)
          wait(owner, monitor)
        end)

      send(owner, {:owned_run_started, request, pid, slot_ref})
      {:ok, pid}
    end

    defp wait(owner, monitor) do
      receive do
        {:"$gen_cast", {:cancel, reason}} ->
          send(owner, {:owned_run_cancelled, self(), reason})
          wait(owner, monitor)

        {:sync, caller, ref} ->
          send(caller, {:owned_run_synced, ref})
          wait(owner, monitor)

        {:DOWN, ^monitor, :process, _pid, _reason} ->
          :ok

        :stop ->
          :ok
      end
    end
  end

  setup do
    gateway_started? =
      Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :lemon_gateway end)

    previous_config = Application.fetch_env(:lemon_gateway, LemonGateway.Config)
    previous_executor = Application.fetch_env(:lemon_gateway, :executor)
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :executor, ControlledExecutor)

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    on_exit(fn ->
      _ = Application.stop(:lemon_gateway)
      restore_env(LemonGateway.Config, previous_config)
      restore_env(:executor, previous_executor)
      if gateway_started?, do: Application.ensure_all_started(:lemon_gateway)
    end)

    :ok
  end

  test "processes execution requests in FIFO order for one conversation" do
    session_key = "thread-worker:#{System.unique_integer([:positive])}"
    worker = start_supervised!({ThreadWorker, thread_key: {:session, session_key}})

    requests =
      Enum.map(["first", "second", "third"], fn prompt ->
        request(session_key, prompt, self())
      end)

    Enum.each(requests, fn request ->
      GenServer.cast(worker, {:enqueue, request})
    end)

    Enum.each(requests, &assert_completed_request/1)
  end

  test "stops after the queue drains" do
    session_key = "thread-worker:#{System.unique_integer([:positive])}"
    worker = start_supervised!({ThreadWorker, thread_key: {:session, session_key}})
    monitor = Process.monitor(worker)

    request = request(session_key, "done", self())
    GenServer.cast(worker, {:enqueue, request})

    assert_completed_request(request)

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    assert_pool_empty()
  end

  test "scheduler loses no fixed IDs while normally drained workers retire" do
    session_key = "retirement-race:#{System.unique_integer([:positive])}"

    for n <- 1..100 do
      request = request(session_key, "turn-#{n}", self())
      assert :ok = LemonGateway.Scheduler.submit_execution(request)
      assert_receive {:executor_started, ^request, run_pid, run_ref}, 1_000
      worker = LemonGateway.ThreadRegistry.whereis(request.conversation_key)
      monitor = Process.monitor(worker)
      complete_executor(request, run_pid, run_ref)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
      assert %{summary: %{completed: %{ok: true}}} = LemonCore.RunStore.get(request.run_id)
    end

    assert_pool_empty()
  end

  test "bounds total start attempts, terminalizes once, and advances FIFO queue" do
    session_key = "thread-worker:#{System.unique_integer([:positive])}"
    thread_key = {:session, session_key}

    :persistent_term.put({SelectiveFailingRunSupervisor, :notify_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({SelectiveFailingRunSupervisor, :notify_pid})
    end)

    worker =
      start_supervised!(
        {ThreadWorker, thread_key: thread_key, run_supervisor: SelectiveFailingRunSupervisor}
      )

    failed = request(session_key, "malformed", self())
    succeeding = request(session_key, "after", self())
    LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(failed.run_id))

    :sys.suspend(worker)
    GenServer.cast(worker, {:enqueue, failed})
    GenServer.cast(worker, {:enqueue, succeeding})
    :sys.resume(worker)

    for _ <- 1..3 do
      assert_receive {:run_start_attempt, run_id}, 1_000
      assert run_id == failed.run_id
    end

    assert_receive {:lemon_gateway_run_completed, ^failed,
                    %{
                      __event__: :completed,
                      ok: false,
                      error: %{
                        type: :run_start_failed,
                        reason: :malformed_request,
                        attempts: 3
                      }
                    }},
                   1_000

    assert_receive %LemonCore.Event{
                     type: :run_completed,
                     meta: %{
                       run_id: failed_run_id,
                       synthetic: true,
                       failure_stage: :run_start
                     }
                   },
                   1_000

    assert failed_run_id == failed.run_id
    assert_completed_request(succeeding)

    assert %{summary: %{completed: %{ok: false, error: %{attempts: 3}}}} =
             LemonCore.RunStore.get(failed.run_id)

    assert_pool_empty()
    refute_receive {:run_start_attempt, _}, 0
    refute_receive {:lemon_gateway_run_completed, ^failed, _}, 0
  end

  test "timeout retries fence stale grants and cannot release the active generation's slot" do
    session_key = "slot-retry:#{System.unique_integer([:positive])}"
    first = request(session_key, "first", self())
    second = request(session_key, "second", self())
    state = queued_state(session_key, [first, second])
    assert_receive {:slot_granted, old_slot, old_token}, 1_000

    state =
      update_in(state.slot_request.requested_at, fn _ ->
        System.monotonic_time(:millisecond) - 30_001
      end)

    {:noreply, state} = ThreadWorker.handle_info(:slot_timeout_check, state)
    assert_receive {:slot_granted, new_slot, new_token} = grant, 1_000
    assert new_token != old_token
    assert new_slot != old_slot

    {:noreply, state} =
      ThreadWorker.handle_info({:slot_granted, old_slot, old_token}, state)

    {:noreply, state} =
      ThreadWorker.handle_info({:slot_request_rejected, old_token, :execution_queue_full}, state)

    {:noreply, state} = ThreadWorker.handle_info({:slot_request_expired, old_token}, state)
    assert_owned_slot(new_slot)
    refute_receive {:owned_run_started, _, _, _}, 0

    {:noreply, state} = ThreadWorker.handle_info(grant, state)
    assert_receive {:owned_run_started, ^first, first_pid, ^new_slot}, 1_000

    # A duplicate grant for the owned slot must not be mistaken for a stale,
    # separately owned slot. Untokenized grants cannot select another request.
    {:noreply, state} = ThreadWorker.handle_info(grant, state)
    {:noreply, state} = ThreadWorker.handle_info({:slot_granted, new_slot}, state)

    {:noreply, state} =
      ThreadWorker.handle_info({:slot_granted, old_slot, old_token}, state)

    assert_owned_slot(new_slot)

    {:noreply, state} =
      ThreadWorker.handle_cast({:cancel_queued, first.run_id, :cancel_one}, state)

    {:noreply, state} =
      ThreadWorker.handle_cast({:cancel_queued, first.run_id, :cancel_two}, state)

    assert_receive {:owned_run_cancelled, ^first_pid, :cancel_one}, 1_000
    assert_receive {:owned_run_cancelled, ^first_pid, :cancel_two}, 1_000
    assert_owned_slot(new_slot)

    {:noreply, state} = kill_owned_run(state)
    {state, _second_pid, second_slot} = grant_owned_run(state, second)
    assert_owned_slot(second_slot)
    {:stop, :normal, _state} = kill_owned_run(state)
    assert_pool_empty()
  end

  test "completion before DOWN consumes ownership once without affecting the next run" do
    session_key = "complete-first:#{System.unique_integer([:positive])}"
    first = request(session_key, "first", self())
    second = request(session_key, "second", self())
    state = queued_state(session_key, [first, second])
    {state, first_pid, first_slot} = grant_owned_run(state, first)
    first_monitor = state.active_run.mon_ref

    # Match Run's contract: its slot release precedes the completion notification.
    Scheduler.release_slot(first_slot)
    {:noreply, state} = ThreadWorker.handle_info({:run_complete, first_pid, %{ok: true}}, state)
    assert_not_monitoring(first_pid)
    {state, second_pid, second_slot} = grant_owned_run(state, second)

    {:noreply, state} = ThreadWorker.handle_info({:run_complete, first_pid, %{ok: true}}, state)

    {:noreply, state} =
      ThreadWorker.handle_info({:DOWN, first_monitor, :process, first_pid, :normal}, state)

    {:noreply, state} =
      ThreadWorker.handle_info(
        {:DOWN, state.active_run.mon_ref, :process, first_pid, :normal},
        state
      )

    {:noreply, state} =
      ThreadWorker.handle_info({:DOWN, make_ref(), :process, second_pid, :normal}, state)

    monitor = Process.monitor(first_pid)
    send(first_pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^first_pid, :normal}, 1_000
    refute_receive {:DOWN, ^first_monitor, :process, ^first_pid, _}, 0
    assert_owned_slot(second_slot)

    {:stop, :normal, _state} = kill_owned_run(state)
    assert_pool_empty()
  end

  test "DOWN before completion releases fallback ownership without inventing a result" do
    session_key = "down-first:#{System.unique_integer([:positive])}"
    first = request(session_key, "first", self())
    second = request(session_key, "second", self())
    state = queued_state(session_key, [first, second])
    {state, first_pid, _first_slot} = grant_owned_run(state, first)
    first_monitor = state.active_run.mon_ref
    {:noreply, state} = kill_owned_run(state)
    assert_not_monitoring(first_pid)
    assert {:ok, nil} = LemonCore.RunStore.fetch(first.run_id)
    refute_receive {:lemon_gateway_run_completed, ^first, _}, 0

    {state, second_pid, second_slot} = grant_owned_run(state, second)
    {:noreply, state} = ThreadWorker.handle_info({:run_complete, first_pid, %{ok: true}}, state)

    {:noreply, state} =
      ThreadWorker.handle_info({:DOWN, first_monitor, :process, first_pid, :killed}, state)

    {:noreply, state} =
      ThreadWorker.handle_cast({:cancel_queued, first.run_id, :late_cancel}, state)

    sync_owned_run(second_pid)
    refute_receive {:owned_run_cancelled, ^second_pid, _}, 0
    assert_owned_slot(second_slot)
    {:stop, :normal, _state} = kill_owned_run(state)
    assert_pool_empty()
  end

  test "cancelling one slot waiter terminalizes only that ID and preserves queue order" do
    Scheduler.request_slot(self(), :blocker)
    assert_receive {:slot_granted, blocker_slot}, 1_000
    session_key = "cancel-waiter:#{System.unique_integer([:positive])}"
    cancelled = request(session_key, "cancelled", self())
    kept = request(session_key, "kept", self())
    state = queued_state(session_key, [cancelled, kept])

    {:noreply, state} =
      ThreadWorker.handle_cast({:cancel_queued, cancelled.run_id, :user_requested}, state)

    {:noreply, state} =
      ThreadWorker.handle_cast({:cancel_queued, cancelled.run_id, :user_requested}, state)

    assert_receive {:lemon_gateway_run_completed, ^cancelled,
                    %{ok: false, error: :user_requested, meta: %{cancelled: true}}},
                   1_000

    assert %{summary: %{completed: %{meta: %{cancelled: true}}}} =
             LemonCore.RunStore.get(cancelled.run_id)

    Scheduler.release_slot(blocker_slot)
    {state, _pid, slot} = grant_owned_run(state, kept)
    assert_owned_slot(slot)
    refute_receive {:owned_run_started, ^cancelled, _, _}, 0
    refute_receive {:lemon_gateway_run_completed, ^cancelled, _}, 0
    {:stop, :normal, _state} = kill_owned_run(state)
    assert_pool_empty()
  end

  test "cancelling the final waiter reclaims a grant already in its mailbox" do
    Scheduler.request_slot(self(), :blocker)
    assert_receive {:slot_granted, blocker_slot}, 1_000
    session_key = "cancel-grant-race:#{System.unique_integer([:positive])}"
    cancelled = request(session_key, "cancelled", self())

    worker =
      start_supervised!(
        {ThreadWorker,
         thread_key: cancelled.conversation_key, run_supervisor: ControlledRunSupervisor}
      )

    monitor = Process.monitor(worker)
    :ok = GenServer.call(worker, {:enqueue, cancelled})
    assert [%{worker: ^worker}] = :queue.to_list(:sys.get_state(Scheduler).waitq)
    :sys.suspend(worker)
    GenServer.cast(worker, {:cancel_queued, cancelled.run_id, :user_requested})
    GenServer.cast(worker, {:cancel_queued, cancelled.run_id, :user_requested})
    Scheduler.release_slot(blocker_slot)
    assert [{_slot, %{worker: ^worker}}] = Map.to_list(:sys.get_state(Scheduler).in_flight)
    :sys.resume(worker)

    assert_receive {:lemon_gateway_run_completed, ^cancelled, %{ok: false}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    assert_pool_empty()

    assert %{summary: %{completed: %{meta: %{cancelled: true}}}} =
             LemonCore.RunStore.get(cancelled.run_id)

    refute_receive {:owned_run_started, _, _, _}, 0
    refute_receive {:lemon_gateway_run_completed, ^cancelled, _}, 0
  end

  defp queued_state(session_key, requests) do
    {:ok, state} =
      ThreadWorker.init(%{
        thread_key: {:session, session_key},
        run_supervisor: ControlledRunSupervisor
      })

    Enum.reduce(requests, state, fn request, state ->
      {:noreply, state} = ThreadWorker.handle_cast({:enqueue, request}, state)
      state
    end)
  end

  defp grant_owned_run(state, request) do
    assert_receive {:slot_granted, slot_ref, _token} = grant, 1_000
    {:noreply, state} = ThreadWorker.handle_info(grant, state)
    assert_receive {:owned_run_started, ^request, pid, ^slot_ref}, 1_000
    {state, pid, slot_ref}
  end

  defp kill_owned_run(state) do
    %{pid: pid, mon_ref: monitor} = state.active_run
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed} = down, 1_000
    ThreadWorker.handle_info(down, state)
  end

  defp assert_owned_slot(slot_ref) do
    scheduler = :sys.get_state(Scheduler)
    assert Map.keys(scheduler.in_flight) == [slot_ref]
    assert :queue.is_empty(scheduler.waitq)
    assert scheduler.worker_counts[self()] == 1
  end

  defp assert_not_monitoring(pid) do
    {:monitors, monitors} = Process.info(self(), :monitors)
    refute {:process, pid} in monitors
  end

  defp sync_owned_run(pid) do
    ref = make_ref()
    send(pid, {:sync, self(), ref})
    assert_receive {:owned_run_synced, ^ref}, 1_000
  end

  defp request(session_key, prompt, notify_pid) do
    %ExecutionRequest{
      run_id: "run_#{System.unique_integer([:positive])}",
      session_key: session_key,
      prompt: prompt,
      conversation_key: {:session, session_key},
      meta: %{notify_pid: notify_pid}
    }
  end

  defp assert_completed_request(%ExecutionRequest{} = request) do
    assert_receive {:executor_started, ^request, run_pid, run_ref}, 2_000
    complete_executor(request, run_pid, run_ref)
  end

  defp complete_executor(request, run_pid, run_ref) do
    send(
      run_pid,
      {:engine_event, run_ref,
       LemonGateway.Event.completed(%{
         engine: "lemon",
         ok: true,
         answer: "Controlled: #{request.prompt}"
       })}
    )

    assert_receive {:lemon_gateway_run_completed, ^request, completed}, 2_000
    assert completed.answer == "Controlled: #{request.prompt}"
  end

  defp assert_pool_empty do
    scheduler = :sys.get_state(Scheduler)
    assert scheduler.in_flight == %{}
    assert :queue.is_empty(scheduler.waitq)
    assert scheduler.monitors == %{}
    assert scheduler.worker_counts == %{}
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:lemon_gateway, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:lemon_gateway, key)
end
