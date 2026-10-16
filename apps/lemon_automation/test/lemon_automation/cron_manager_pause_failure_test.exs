defmodule LemonAutomation.CronManagerPauseFailureTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}
  alias LemonCore.Store

  # Use the Store's existing backend seam, not a scheduler policy override.
  defmodule FailureBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{data: %{}, failure: nil}}

    @impl true
    def put(%{failure: {:put, table, key}}, table, key, _value),
      do: {:error, :injected_resume_failure}

    def put(state, table, key, value),
      do: {:ok, %{state | data: Map.put(state.data, {table, key}, value)}}

    @impl true
    def put_new(state, table, key, value) do
      if Map.has_key?(state.data, {table, key}),
        do: {:exists, state},
        else: put(state, table, key, value)
    end

    @impl true
    def get(%{failure: {:get, table, key}}, table, key),
      do: {:error, :injected_resume_failure}

    def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

    @impl true
    def delete(%{failure: {:delete, table, key}}, table, key),
      do: {:error, :injected_resume_failure}

    def delete(state, table, key),
      do: {:ok, %{state | data: Map.delete(state.data, {table, key})}}

    @impl true
    def list(%{failure: {:list, table}}, table), do: {:error, :injected_resume_failure}

    def list(%{failure: {:list_after, table, 0}}, table),
      do: {:error, :injected_resume_failure}

    def list(%{failure: {:list_after, table, remaining}} = state, table) do
      rows = for {{^table, key}, value} <- state.data, do: {key, value}
      {:ok, rows, %{state | failure: {:list_after, table, remaining - 1}}}
    end

    def list(state, table) do
      {:ok, for({{^table, key}, value} <- state.data, do: {key, value}), state}
    end
  end

  defmodule PassingPreflight do
    def check(_job), do: :ok
    def current_default_model, do: {:ok, "test:model"}
  end

  defmodule Submitter do
    def submit(job, run, _opts) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:cron_submit, job.id, run.id, run.triggered_by}
      )

      {:ok, "done"}
    end
  end

  setup do
    # Prevent the application's manager from observing the isolated backend.
    # Tests below own callback state or an independent supervision tree.
    manager = Process.whereis(CronManager)
    if manager, do: :sys.suspend(manager)
    original = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      %{state | backend: FailureBackend, backend_state: %{data: %{}, failure: nil}}
    end)

    previous_submitter = Application.get_env(:lemon_automation, :cron_run_submitter)
    previous_preflight = Application.get_env(:lemon_automation, :cron_preflight_mod)
    Application.put_env(:lemon_automation, :cron_run_submitter, Submitter)
    Application.put_env(:lemon_automation, :cron_preflight_mod, PassingPreflight)
    :persistent_term.put({Submitter, :test_pid}, self())

    on_exit(fn ->
      restore_env(:cron_run_submitter, previous_submitter)
      restore_env(:cron_preflight_mod, previous_preflight)
      :persistent_term.erase({Submitter, :test_pid})
      :sys.replace_state(Store, fn _ -> original end)
      if manager && Process.alive?(manager), do: :sys.resume(manager)
    end)

    now = LemonCore.Clock.now_ms()
    paused_at = now - 60_000
    :ok = CronStore.put_global_pause(paused_at)
    %{now: now, paused_at: paused_at}
  end

  test "strict job enumeration distinguishes unavailable storage from an empty inventory" do
    assert {:ok, []} = CronStore.list_jobs_result()
    inject({:list, :cron_jobs})
    assert {:error, :store_unavailable} = CronStore.list_jobs_result()
    assert [] = CronStore.list_jobs()
  end

  test "resume reloads jobs lost from memory during a paused restart", context do
    id = "pause_restart_inventory"
    due = context.now - 30_000
    paused_at = context.paused_at
    job = store_job(id, due, false)
    source = pending_retry(id, due)

    inject({:list, :cron_jobs})
    {:ok, restarted} = CronManager.init([])
    assert restarted.jobs == %{}
    assert restarted.restoration_pending

    assert {:reply, {:error, :store_unavailable}, restarted} =
             CronManager.handle_call(:resume_all, from(), restarted)

    assert {:ok, %{paused_at_ms: ^paused_at}} = CronStore.global_pause()

    # Enumeration recovers, but the durable slot cannot yet be advanced. The
    # empty in-memory map must not allow resume to bypass that failed write.
    inject({:put, :cron_jobs, id})

    assert {:reply, {:error, :store_unavailable}, restarted} =
             CronManager.handle_call(:resume_all, from(), restarted)

    assert {:ok, %{paused_at_ms: ^paused_at}} = CronStore.global_pause()
    assert CronStore.get_job(id).next_run_at_ms == due
    assert_held(restarted, id)

    inject(nil)

    assert {:reply, {:ok, %{resumed: true, skipped_job_count: 1, skipped_retry_count: 1}},
            resumed} =
             CronManager.handle_call(:resume_all, from(), restarted)

    assert {:ok, nil} = CronStore.global_pause()
    assert resumed.jobs[id].next_run_at_ms > context.now
    assert CronStore.get_job(id).next_run_at_ms == resumed.jobs[id].next_run_at_ms
    assert CronStore.get_run(source.id).meta.retry_abandoned == "global_pause"
    assert {:noreply, resumed} = restore_schedules(resumed)
    refute resumed.restoration_pending

    # The default catch-up policy on a later restart cannot recover either
    # missed occurrence after the marker has been cleared.
    {:ok, after_resume} = CronManager.init([])
    assert after_resume.jobs[id].next_run_at_ms == resumed.jobs[id].next_run_at_ms
    refute Map.has_key?(after_resume.catch_up_slots, id)
    assert_held(after_resume, id)
    assert CronStore.get_run(CronStore.scheduled_run_id(id, job.next_run_at_ms)) == nil
    assert CronStore.get_run(CronStore.retry_run_id(source.id, 1)) == nil
  end

  for once <- [false, true], failure <- [:marker_read, :durable_skip] do
    @once once
    @startup_failure failure
    test "startup holds an expired #{if @once, do: "one-shot", else: "recurring"} job pending after #{@startup_failure} failure",
         context do
      once = @once
      failure = @startup_failure
      id = "startup_skip_failure_#{once}_#{failure}"
      # Beyond the maximum catch-up grace, regardless of the configured policy.
      due = context.now - 86_400_000
      store_job(id, due, once)
      :ok = CronStore.clear_global_pause()

      inject(startup_failure_operation(failure, once, id))

      assert {:ok, pending} = CronManager.init([])
      assert pending.restoration_pending
      assert is_reference(pending.restoration_timer)
      assert pending.restoration_backoff_ms == 500
      assert pending.jobs[id].next_run_at_ms == due
      assert CronStore.get_job(id).next_run_at_ms == due

      if failure == :durable_skip do
        assert {:ok, nil} = CronStore.global_pause()
        assert_pending_status(pending, true)
      end

      assert_held(pending, id)

      assert {:noreply, pending} = restore_schedules(pending)
      assert pending.restoration_pending
      assert CronStore.get_job(id).next_run_at_ms == due
      assert CronStore.get_run(CronStore.scheduled_run_id(id, due)) == nil

      # A readable, absent marker is not enough: dispatch remains held until
      # restoration has durably skipped the expired slot.
      inject(nil)
      assert {:ok, nil} = CronStore.global_pause()
      assert_held(pending, id)
      assert_pending_status(pending, true)
      assert {:noreply, pending} = CronManager.handle_info({:execute_job, id, :schedule}, pending)
      assert CronStore.get_run(CronStore.scheduled_run_id(id, due)) == nil

      assert {:noreply, restored} = restore_schedules(pending)
      assert_recovered_skip(restored, id, due, once, context.now)
      assert_pending_status(restored, false)

      # A normal tick after recovery cannot claim the old slot in either lane.
      assert_held(restored, id)
      assert CronStore.get_run(CronStore.scheduled_run_id(id, due)) == nil
    end
  end

  test "marker recovery does not dispatch a durable retry before restoration", context do
    id = "startup_marker_retry"
    store_job(id, context.now + 3_600_000, false)
    source = pending_retry(id, context.now - 1_000)
    retry_id = CronStore.retry_run_id(source.id, 1)
    tasks = start_supervised!(Task.Supervisor)
    :ok = CronStore.clear_global_pause()
    inject({:get, :cron_settings, :global_pause})

    assert {:ok, pending} = CronManager.init(task_supervisor: tasks)
    assert pending.restoration_pending
    assert CronStore.get_run(retry_id) == nil

    inject(nil)
    assert {:ok, nil} = CronStore.global_pause()
    assert_held(pending, id)
    assert CronStore.get_run(retry_id) == nil
    refute_receive {:cron_submit, ^id, _, _}, 20

    assert {:noreply, restored} = restore_schedules(pending)
    refute restored.restoration_pending
    assert_receive {:cron_submit, ^id, ^retry_id, :retry}, 1_000
    assert %CronRun{triggered_by: :retry} = CronStore.get_run(retry_id)
  end

  test "restoration retries back off from 250 milliseconds to a five-second cap" do
    inject({:get, :cron_settings, :global_pause})
    assert {:ok, pending} = CronManager.init([])
    assert pending.restoration_pending
    assert is_reference(pending.restoration_timer)
    assert pending.restoration_backoff_ms == 500

    pending =
      Enum.reduce([1_000, 2_000, 4_000, 5_000, 5_000], pending, fn expected, state ->
        assert {:noreply, retried} = restore_schedules(state)
        assert retried.restoration_pending
        assert is_reference(retried.restoration_timer)
        refute retried.restoration_timer == state.restoration_timer
        assert retried.restoration_backoff_ms == expected
        retried
      end)

    inject(nil)
    assert {:noreply, restored} = restore_schedules(pending)
    refute restored.restoration_pending
    assert restored.restoration_timer == nil
    assert restored.restoration_backoff_ms == 250
  end

  for once <- [false, true] do
    @once once
    test "permanent manager and task supervisor survive prolonged #{if @once, do: "delete", else: "write"} failure and recover",
         context do
      once = @once
      id = "supervised_skip_failure_#{once}"
      future_id = id <> "_future"
      due = context.now - 86_400_000
      store_job(id, due, once)
      future = store_job(future_id, context.now + 3_600_000, false)
      :ok = CronStore.clear_global_pause()
      inject(startup_failure_operation(:durable_skip, once, id))

      {supervisor, manager, sibling} = start_recovery_supervisor()
      manager_ref = Process.monitor(manager)
      sibling_ref = Process.monitor(sibling)
      initial = :sys.get_state(manager)
      assert initial.restoration_pending
      assert initial.task_supervisor == __MODULE__.RecoveryTaskSupervisor
      assert {:ok, nil} = CronStore.global_pause()

      assert {:ok, %{paused: false, paused_at_ms: nil, restoration_pending: true}} =
               GenServer.call(manager, :pause_status)

      GenServer.cast(manager, :tick)
      send(manager, :retry_tick)
      send(manager, {:execute_job, id, :schedule})
      assert :sys.get_state(manager).restoration_pending

      # Outlast the production supervisor's default restart-intensity window,
      # with real restoration timers firing against the failing backend.
      started_at = System.monotonic_time(:millisecond)
      refute_receive {:DOWN, ^manager_ref, :process, ^manager, _}, 5_100
      assert System.monotonic_time(:millisecond) - started_at >= 5_100
      refute_receive {:DOWN, ^sibling_ref, :process, ^sibling, _}, 0
      assert_recovery_children(supervisor, manager, sibling)

      pending = :sys.get_state(manager)
      assert pending.restoration_pending

      assert {:ok, %{paused: false, restoration_pending: true}} =
               GenServer.call(manager, :pause_status)

      refute pending.restoration_timer == initial.restoration_timer
      assert CronStore.get_job(id).next_run_at_ms == due
      assert CronStore.get_run(CronStore.scheduled_run_id(id, due)) == nil
      refute_receive {:cron_submit, _, _, _}, 0
      assert_sibling_responds(sibling)

      inject(nil)
      # Deliver the retry explicitly, then use the server mailbox as a barrier.
      send(manager, :restore_schedules)

      assert {:ok, %{paused: false, restoration_pending: false}} =
               GenServer.call(manager, :pause_status)

      restored = :sys.get_state(manager)
      assert_recovered_skip(restored, id, due, once, context.now)
      assert restored.jobs[future_id].next_run_at_ms == future.next_run_at_ms
      assert CronStore.get_job(future_id).next_run_at_ms == future.next_run_at_ms

      GenServer.cast(manager, :tick)
      send(manager, :retry_tick)
      _state = :sys.get_state(manager)
      assert CronStore.get_run(CronStore.scheduled_run_id(id, due)) == nil
      refute_receive {:cron_submit, _, _, _}, 20

      # Advance the future job to its next due slot, as the normal clock would,
      # and prove scheduling and its sibling-supervised worker are usable again.
      scheduled_for = LemonCore.Clock.now_ms() - 1
      ready = %{restored.jobs[future_id] | next_run_at_ms: scheduled_for}
      :ok = CronStore.put_job(ready)
      :sys.replace_state(manager, &put_in(&1.jobs[future_id], ready))
      run_id = CronStore.scheduled_run_id(future_id, scheduled_for)
      GenServer.cast(manager, :tick)
      assert_receive {:cron_submit, ^future_id, ^run_id, :schedule}, 1_000
      assert eventually(fn -> match?(%CronRun{status: :completed}, CronStore.get_run(run_id)) end)
      assert CronStore.get_job(future_id).next_run_at_ms > LemonCore.Clock.now_ms()
      GenServer.cast(manager, :tick)
      _state = :sys.get_state(manager)
      refute_receive {:cron_submit, ^future_id, _, _}, 20
      assert CronStore.get_run(CronStore.scheduled_run_id(id, due)) == nil
      assert_recovery_children(supervisor, manager, sibling)
      assert_sibling_responds(sibling)
    end
  end

  test "strict run enumerations distinguish unavailable storage from empty history" do
    assert {:ok, []} = CronStore.pending_retries_result()
    assert {:ok, []} = CronStore.active_runs_result()
    inject({:list, :cron_runs})
    assert {:error, :store_unavailable} = CronStore.pending_retries_result()
    assert {:error, :store_unavailable} = CronStore.active_runs_result()
    assert [] = CronStore.pending_retries()
  end

  for failure <- [
        :retry_enumeration,
        :job_reanchor,
        :once_retirement,
        :once_incident_retirement,
        :retry_abandonment
      ] do
    @failure failure
    test "resume retains the durable pause after #{@failure} failure", context do
      failure = @failure
      id = "pause_failure_#{failure}"
      due = context.now - 30_000
      job = store_job(id, due, failure in [:once_retirement, :once_incident_retirement])
      retry_job_id = id <> "_retry"
      store_job(retry_job_id, context.now + 3_600_000, false)
      source = pending_retry(retry_job_id, due)
      {:ok, state} = CronManager.init([])

      inject(failure_operation(failure, id, source.id))

      assert {:reply, {:error, _reason}, state} =
               CronManager.handle_call(:resume_all, from(), state)

      assert {:ok, %{paused_at_ms: paused_at}} = CronStore.global_pause()
      assert paused_at == context.paused_at

      # Storage recovers, but a restart must still see the retained marker. It
      # cannot turn the failed resume into catch-up dispatch in either lane.
      inject(nil)
      assert_held(state, id)
      {:ok, restarted} = CronManager.init([])
      assert_held(restarted, id)
      assert {:ok, %{paused_at_ms: ^paused_at}} = CronStore.global_pause()
      assert CronStore.get_run(CronStore.scheduled_run_id(id, job.next_run_at_ms)) == nil
      assert CronStore.get_run(CronStore.retry_run_id(source.id, 1)) == nil

      assert {:reply, {:ok, %{resumed: true}}, resumed} =
               CronManager.handle_call(:resume_all, from(), restarted)

      assert {:ok, nil} = CronStore.global_pause()
      assert_held(resumed, id)
      assert CronStore.get_run(CronStore.scheduled_run_id(id, job.next_run_at_ms)) == nil
      assert CronStore.get_run(CronStore.retry_run_id(source.id, 1)) == nil
      assert CronStore.get_run(source.id).meta.retry_abandoned == "global_pause"

      if job.once do
        assert CronStore.get_job(id) == nil
      else
        assert CronStore.get_job(id).next_run_at_ms > context.now
      end
    end
  end

  defp failure_operation(:retry_enumeration, _id, _source_id), do: {:list_after, :cron_runs, 1}
  defp failure_operation(:job_reanchor, id, _source_id), do: {:put, :cron_jobs, id}
  defp failure_operation(:once_retirement, id, _source_id), do: {:delete, :cron_jobs, id}

  defp failure_operation(:once_incident_retirement, id, _source_id),
    do: {:delete, :cron_failure_alert_state, id}

  defp failure_operation(:retry_abandonment, _id, source_id), do: {:put, :cron_runs, source_id}

  defp restore_schedules(state) do
    if state.restoration_timer, do: Process.cancel_timer(state.restoration_timer)
    CronManager.handle_info(:restore_schedules, state)
  end

  defp assert_recovered_skip(state, id, due, once, now) do
    refute state.restoration_pending
    assert state.restoration_timer == nil
    refute Map.has_key?(state.catch_up_slots, id)
    assert CronStore.get_run(CronStore.scheduled_run_id(id, due)) == nil

    if once do
      refute Map.has_key?(state.jobs, id)
      assert CronStore.get_job(id) == nil
    else
      assert state.jobs[id].next_run_at_ms > now
      assert CronStore.get_job(id).next_run_at_ms == state.jobs[id].next_run_at_ms
    end

    assert [%{job_id: ^id}] =
             CronStore.list_audit_events(job_id: id, action: :missed_slot_skipped)
  end

  defp startup_failure_operation(:marker_read, _once, _id),
    do: {:get, :cron_settings, :global_pause}

  defp startup_failure_operation(:durable_skip, true, id), do: {:delete, :cron_jobs, id}
  defp startup_failure_operation(:durable_skip, false, id), do: {:put, :cron_jobs, id}

  defp start_recovery_supervisor do
    children = [
      {Task.Supervisor, name: __MODULE__.RecoveryTaskSupervisor},
      %{
        id: CronManager,
        start:
          {GenServer, :start_link,
           [CronManager, [task_supervisor: __MODULE__.RecoveryTaskSupervisor]]},
        restart: :permanent,
        type: :worker
      }
    ]

    supervisor =
      start_supervised!(%{
        id: :recovery_supervisor,
        start:
          {Supervisor, :start_link,
           [children, [strategy: :one_for_one, max_restarts: 3, max_seconds: 5]]},
        type: :supervisor
      })

    children = Supervisor.which_children(supervisor)
    {CronManager, manager, :worker, _} = List.keyfind(children, CronManager, 0)

    {_, sibling, :supervisor, _} =
      List.keyfind(children, __MODULE__.RecoveryTaskSupervisor, 0)

    {supervisor, manager, sibling}
  end

  defp assert_recovery_children(supervisor, manager, sibling) do
    assert Process.alive?(supervisor)
    assert Process.alive?(manager)
    assert Process.alive?(sibling)
    children = Supervisor.which_children(supervisor)
    assert {CronManager, ^manager, :worker, _} = List.keyfind(children, CronManager, 0)

    assert {_, ^sibling, :supervisor, _} =
             List.keyfind(children, __MODULE__.RecoveryTaskSupervisor, 0)
  end

  defp assert_sibling_responds(sibling) do
    test_pid = self()
    token = make_ref()
    assert {:ok, _} = Task.Supervisor.start_child(sibling, fn -> send(test_pid, token) end)
    assert_receive ^token, 1_000
  end

  defp assert_pending_status(state, pending?) do
    assert {:reply, {:ok, %{paused: false, paused_at_ms: nil, restoration_pending: ^pending?}},
            ^state} = CronManager.handle_call(:pause_status, from(), state)
  end

  defp eventually(fun, attempts \\ 600)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_automation, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_automation, key, value)

  defp assert_held(state, id) do
    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    assert {:noreply, _state} = CronManager.handle_info(:retry_tick, state)
    refute_receive {:submit_claimed_run, ^id, _}, 20
  end

  defp inject(failure) do
    :sys.replace_state(Store, fn state ->
      %{state | backend_state: %{state.backend_state | failure: failure}}
    end)
  end

  defp store_job(id, due, once) do
    job =
      CronJob.new(%{
        id: id,
        name: id,
        schedule: "0 9 * * *",
        timezone: "UTC",
        agent_id: "test",
        session_key: "agent:test:main",
        prompt: "test",
        max_retries: 1,
        once: once
      })

    job = %{job | next_run_at_ms: due}
    :ok = CronStore.put_job(job)
    job
  end

  defp pending_retry(id, due) do
    source = id |> CronRun.new(:schedule) |> CronRun.fail("boom")

    source = %{
      source
      | meta: %{retry_due_at_ms: due, retry_next_attempt: 1, retry_root_id: source.id}
    }

    :ok = CronStore.put_run(source)
    source
  end

  defp from, do: {self(), make_ref()}
end
