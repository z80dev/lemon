defmodule LemonAutomation.CronManagerPauseTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore, TestCronManager}
  alias LemonAutomation.Doctor.Checks.Cron, as: CronCheck
  alias LemonAutomation.Tools.Cron, as: CronTool

  defmodule Submitter do
    def submit(_job, run, _opts) do
      send(
        :persistent_term.get({__MODULE__, :test_pid}),
        {:cron_submit, run.id, run.triggered_by}
      )

      {:ok, "done"}
    end
  end

  defmodule BlockingPreflight do
    def check(job) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:preflight_blocked, job.id, self()})

      receive do
        :release_preflight -> :ok
      end
    end

    def current_default_model, do: {:ok, "test:model"}
  end

  setup do
    previous = Application.get_env(:lemon_automation, :cron_run_submitter)
    Application.put_env(:lemon_automation, :cron_run_submitter, Submitter)
    :persistent_term.put({Submitter, :test_pid}, self())

    base = "pause_#{System.unique_integer([:positive, :monotonic])}"
    ids = [base, base <> "_once", base <> "_off", base <> "_future"]
    :ok = CronStore.clear_global_pause()

    on_exit(fn ->
      CronStore.clear_global_pause()
      :persistent_term.erase({Submitter, :test_pid})

      if previous,
        do: Application.put_env(:lemon_automation, :cron_run_submitter, previous),
        else: Application.delete_env(:lemon_automation, :cron_run_submitter)

      for id <- ids do
        if Process.whereis(CronManager), do: CronManager.remove(id)
        CronStore.delete_job(id)
        for run <- CronStore.list_runs(id, limit: 10_000), do: CronStore.delete_run(run.id)
      end
    end)

    %{id: base, once_id: base <> "_once", off_id: base <> "_off", future_id: base <> "_future"}
  end

  test "the pause survives a daemon restart and leaves stored schedules untouched", %{id: id} do
    TestCronManager.isolate!()

    # Inside catch-up grace, so an unpaused restart would claim this slot once.
    due = LemonCore.Clock.now_ms() - 1_800_000
    store_job(id, next_run_at_ms: due)

    assert {:ok, %{paused: true, paused_at_ms: paused_at}} = CronManager.pause_all()

    old_pid = Process.whereis(CronManager)
    GenServer.stop(CronManager)
    assert await(fn -> (pid = Process.whereis(CronManager)) && pid != old_pid end)

    assert {:ok, %{paused: true, paused_at_ms: ^paused_at}} = CronManager.pause_status()
    state = :sys.get_state(CronManager)
    assert state.jobs[id].next_run_at_ms == due
    refute Map.has_key?(state.catch_up_slots, id)

    CronManager.tick()
    _ = CronManager.list()
    assert CronStore.list_runs(id) == []
    assert CronStore.get_job(id).next_run_at_ms == due

    assert {:ok, %{resumed: true}} = CronManager.resume_all()
  end

  test "pausing again keeps the original pause time and one audit" do
    assert {:ok, %{paused: true, paused_at_ms: first}} = CronManager.pause_all()
    Process.sleep(2)
    assert {:ok, %{paused: true, paused_at_ms: ^first}} = CronManager.pause_all()

    paused_audits =
      CronStore.list_audit_events(limit: 1_000, action: :all_jobs_paused)
      |> Enum.filter(&(&1.ts_ms >= first))

    assert length(paused_audits) == 1
    assert {:ok, %{resumed: true}} = CronManager.resume_all()
    assert {:ok, %{resumed: false}} = CronManager.resume_all()
    assert {:ok, %{paused: false, paused_at_ms: nil}} = CronManager.pause_status()
  end

  test "scheduled slots, retries and wake are held back while paused", %{id: id} do
    due = LemonCore.Clock.now_ms() - 1_000
    store_job(id, next_run_at_ms: due, max_retries: 1)
    {state, _paused_at} = paused_state([id])

    source = pending_retry(id, due_at_ms: LemonCore.Clock.now_ms() - 500)

    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    assert {:noreply, state} = CronManager.handle_info(:retry_tick, state)

    refute_receive {:submit_claimed_run, ^id, _}
    assert state.jobs[id].next_run_at_ms == due
    assert CronStore.get_job(id).next_run_at_ms == due
    assert CronStore.list_runs(id) == [CronStore.get_run(source.id)]
    assert CronStore.get_run(CronStore.retry_run_id(source.id, 1)) == nil

    assert {:reply, {:error, :cron_paused}, _} =
             CronManager.handle_call({:wake, id, []}, from(), state)

    # An explicit operator run is not a scheduled launch.
    assert {:reply, {:ok, %CronRun{triggered_by: :manual}}, _} =
             CronManager.handle_call({:run_now, id}, from(), state)

    assert_receive {:cron_submit, _, :manual}, 5_000
  end

  test "a slot claimed just before the pause is aborted instead of submitted", %{id: id} do
    store_job(id, next_run_at_ms: LemonCore.Clock.now_ms() - 1_000)
    {:ok, state} = CronManager.init([])
    state = %{state | jobs: Map.take(state.jobs, [id])}

    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    assert_receive {:submit_claimed_run, ^id, run_id}

    {:reply, {:ok, _}, state} = CronManager.handle_call(:pause_all, from(), state)
    assert {:noreply, _state} = CronManager.handle_info({:submit_claimed_run, id, run_id}, state)

    refute_receive {:cron_submit, ^run_id, _}, 200

    assert %CronRun{status: :aborted, error: "Cron paused before submission"} =
             CronStore.get_run(run_id)
  end

  for trigger <- [:schedule, :retry] do
    @trigger trigger
    test "pause invalidates a #{@trigger} worker blocked before the default submission claim", %{
      id: id
    } do
      previous_preflight = Application.get_env(:lemon_automation, :cron_preflight_mod)
      Application.put_env(:lemon_automation, :cron_preflight_mod, BlockingPreflight)
      Application.delete_env(:lemon_automation, :cron_run_submitter)
      :persistent_term.put({BlockingPreflight, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({BlockingPreflight, :test_pid})

        if previous_preflight,
          do: Application.put_env(:lemon_automation, :cron_preflight_mod, previous_preflight),
          else: Application.delete_env(:lemon_automation, :cron_preflight_mod)

        :erlang.trace_pattern({LemonRouter, :submit, 1}, false, [])
      end)

      job = store_job(id, next_run_at_ms: LemonCore.Clock.now_ms() + 3_600_000)
      run = id |> CronRun.new(@trigger) |> CronRun.start(LemonCore.Id.run_id())
      assert :ok = CronStore.put_run(run)
      :sys.replace_state(CronManager, &put_in(&1.jobs[id], job))
      send(Process.whereis(CronManager), {:submit_claimed_run, id, run.id})

      assert_receive {:preflight_blocked, ^id, worker}, 5_000
      monitor = Process.monitor(worker)
      on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)
      :erlang.trace_pattern({LemonRouter, :submit, 1}, true, [])
      :erlang.trace(worker, true, [:call])
      refute CronStore.get_run(run.id).meta[:submission_started]

      assert {:ok, %{paused: true}} = CronManager.pause_all()

      assert %CronRun{status: :aborted, error: "Cron paused before submission"} =
               CronStore.get_run(run.id)

      assert {:ok, %{resumed: true}} = CronManager.resume_all()
      send(worker, :release_preflight)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
      delivered = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, ^worker, ^delivered}, 5_000
      refute_receive {:trace, ^worker, :call, {LemonRouter, :submit, _}}
      assert await(fn -> not Map.has_key?(:sys.get_state(CronManager).tasks, run.id) end)

      assert %CronRun{status: :aborted, error: "Cron paused before submission"} =
               CronStore.get_run(run.id)

      refute CronStore.get_run(run.id).meta[:submission_started]
    end
  end

  test "a jitter timer delivered after pause and resume cannot resurrect its claim", %{id: id} do
    store_job(id, jitter_sec: 1, next_run_at_ms: LemonCore.Clock.now_ms() - 1_000)
    {:ok, state} = CronManager.init([])
    state = %{state | jobs: Map.take(state.jobs, [id])}
    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    assert [%CronRun{id: run_id, status: :running}] = CronStore.list_runs(id)

    assert {:reply, {:ok, _}, state} = CronManager.handle_call(:pause_all, from(), state)
    assert %CronRun{status: :aborted} = CronStore.get_run(run_id)

    assert {:reply, {:ok, %{resumed: true}}, state} =
             CronManager.handle_call(:resume_all, from(), state)

    assert_receive {:submit_claimed_run, ^id, ^run_id}, 5_000

    assert {:noreply, state} =
             CronManager.handle_info({:submit_claimed_run, id, run_id}, state)

    refute Map.has_key?(state.tasks, run_id)
    refute_receive {:cron_submit, ^run_id, _}

    assert %CronRun{status: :aborted, error: "Cron paused before submission"} =
             CronStore.get_run(run_id)
  end

  test "pause preserves manual claims and scheduled work whose submission has started", %{id: id} do
    store_job(id, next_run_at_ms: LemonCore.Clock.now_ms() + 3_600_000)
    {:ok, state} = CronManager.init([])
    state = %{state | jobs: Map.take(state.jobs, [id])}
    manual = id |> CronRun.new(:manual) |> CronRun.start(LemonCore.Id.run_id())
    started = id |> CronRun.new(:schedule) |> CronRun.start(LemonCore.Id.run_id())
    assert :ok = CronStore.put_run(manual)
    assert :ok = CronStore.put_run(started)

    assert {:reply, :ok, state} =
             CronManager.handle_call(
               {:claim_submission, started.id, started.run_id, "agent:test:main"},
               from(),
               state
             )

    started = CronStore.get_run(started.id)
    assert started.meta.submission_started
    assert {:reply, {:ok, _}, state} = CronManager.handle_call(:pause_all, from(), state)
    assert CronStore.get_run(manual.id) == manual
    assert CronStore.get_run(started.id) == started

    assert {:reply, :ok, _state} =
             CronManager.handle_call(
               {:claim_submission, manual.id, manual.run_id, "agent:test:main"},
               from(),
               state
             )

    assert %CronRun{status: :running, meta: %{submission_started: true}} =
             CronStore.get_run(manual.id)
  end

  test "resume skips missed slots and each job continues at its next schedule", %{
    id: id,
    once_id: once_id,
    off_id: off_id,
    future_id: future_id
  } do
    now = LemonCore.Clock.now_ms()
    missed = now - 600_000
    individually_paused_at = now - 700_000
    future = now + 3_600_000

    store_job(id, next_run_at_ms: missed)
    store_job(once_id, once: true, next_run_at_ms: missed)
    store_job(off_id, enabled: false, next_run_at_ms: individually_paused_at)
    store_job(future_id, next_run_at_ms: future)

    {state, _paused_at} = paused_state([id, once_id, off_id, future_id])
    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    refute_receive {:submit_claimed_run, _, _}

    assert {:reply, {:ok, result}, state} = CronManager.handle_call(:resume_all, from(), state)
    assert %{resumed: true, skipped_job_count: 2, skipped_retry_count: 0} = result
    assert {:ok, %{paused: false, paused_at_ms: nil}} = CronManager.pause_status()

    # Nothing is caught up: the missed run is gone and the job moves on.
    assert state.jobs[id].next_run_at_ms > now
    assert CronStore.get_job(id).next_run_at_ms == state.jobs[id].next_run_at_ms
    refute Map.has_key?(state.jobs, once_id)
    assert CronStore.get_job(once_id) == nil
    assert state.jobs[off_id].next_run_at_ms == individually_paused_at
    refute state.jobs[off_id].enabled
    assert state.jobs[future_id].next_run_at_ms == future
    assert CronStore.list_runs(id) == []

    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    refute_receive {:submit_claimed_run, _, _}
    assert CronStore.list_runs(id) == []

    skipped =
      for event <- CronStore.list_audit_events(limit: 1_000, action: :missed_slot_skipped),
          event.job_id in [id, once_id],
          do: {event.job_id, to_string(event.reason)}

    assert Enum.sort(skipped) == Enum.sort([{id, "global_pause"}, {once_id, "global_pause"}])

    assert [%{status: "resumed"}] =
             CronStore.list_audit_events(action: :all_jobs_resumed, limit: 1)

    # When the next slot arrives the job runs normally, exactly once.
    due = %{state.jobs[id] | next_run_at_ms: LemonCore.Clock.now_ms() - 1}
    CronStore.put_job(due)
    state = put_in(state.jobs[id], due)
    assert {:noreply, state} = CronManager.handle_cast(:tick, state)
    assert_receive {:submit_claimed_run, ^id, run_id}
    assert [%CronRun{id: ^run_id, triggered_by: :schedule}] = CronStore.list_runs(id)
    assert state.jobs[id].next_run_at_ms > LemonCore.Clock.now_ms()
    assert {:noreply, _state} = CronManager.handle_cast(:tick, state)
    refute_receive {:submit_claimed_run, ^id, _}
  end

  test "retries due during the pause are skipped; earlier, later and per-job-paused ones wait", %{
    id: id,
    off_id: off_id
  } do
    store_job(id, max_retries: 1, next_run_at_ms: LemonCore.Clock.now_ms() + 3_600_000)
    store_job(off_id, enabled: false, max_retries: 1)
    {state, paused_at} = paused_state([id, off_id])

    during = pending_retry(id, due_at_ms: paused_at + 1)
    before_pause = pending_retry(id, due_at_ms: paused_at - 60_000)
    later = pending_retry(id, due_at_ms: LemonCore.Clock.now_ms() + 3_600_000)
    individually_paused = pending_retry(off_id, due_at_ms: paused_at + 1)

    Process.sleep(3)
    assert {:reply, {:ok, result}, _state} = CronManager.handle_call(:resume_all, from(), state)
    assert result.skipped_retry_count == 1

    pending = for run <- CronStore.pending_retries(), run.job_id in [id, off_id], do: run.id
    assert Enum.sort(pending) == Enum.sort([before_pause.id, later.id, individually_paused.id])
    assert CronStore.get_run(during.id).meta.retry_abandoned == "global_pause"
    assert CronStore.get_run(CronStore.retry_run_id(during.id, 1)) == nil

    assert [%{job_id: ^id, run_id: run_id}] =
             CronStore.list_audit_events(limit: 1, action: :retry_skipped)

    assert run_id == during.id

    # Abandoned intent is history, not a reason to keep the run forever.
    abandoned = %{CronStore.get_run(during.id) | started_at_ms: 1}
    CronStore.put_run(abandoned)
    newer = id |> CronRun.new(:manual) |> CronRun.complete("ok")
    CronStore.put_run(%{newer | started_at_ms: 2})
    assert :ok = CronStore.cleanup_old_runs(1)
    assert CronStore.get_run(during.id) == nil
    assert CronStore.get_run(newer.id)
    assert CronStore.get_run(before_pause.id)
  end

  test "status shows the pause across the manager, the cron tool and doctor" do
    tool = CronTool.tool(".", session_key: LemonCore.SessionKey.main("default"))

    assert %{"paused" => false, "pausedAtMs" => nil} =
             call_tool(tool, %{"action" => "status"}).details

    refute pause_check(CronCheck.run([]))

    paused = call_tool(tool, %{"action" => "pause_all"})
    assert %{"paused" => true, "pausedAtMs" => paused_at} = paused.details
    assert is_integer(paused_at)

    assert %{"paused" => true, "pausedAtMs" => ^paused_at} =
             call_tool(tool, %{"action" => "status"}).details

    assert {:ok, %{paused: true, paused_at_ms: ^paused_at}} = CronManager.pause_status()

    assert %{status: :warn} = check = pause_check(CronCheck.run([]))
    assert check.remediation =~ "lemon cron resume --all"

    resumed = call_tool(tool, %{"action" => "resume_all"})
    assert %{"paused" => false, "resumed" => true, "skippedJobCount" => _} = resumed.details
    assert %{"paused" => false} = call_tool(tool, %{"action" => "status"}).details
    refute pause_check(CronCheck.run([]))

    assert %{"resumed" => false} = call_tool(tool, %{"action" => "resume_all"}).details
  end

  test "the store marker is write-once and keeps its original time" do
    assert {:ok, nil} = CronStore.global_pause()
    assert :ok = CronStore.put_global_pause(1_000)
    assert {:error, :exists} = CronStore.put_global_pause(2_000)
    assert {:ok, %{paused_at_ms: 1_000}} = CronStore.global_pause()
    assert :ok = CronStore.clear_global_pause()
    assert {:ok, nil} = CronStore.global_pause()
  end

  test "an unrecognised marker still reads as paused" do
    :ok = LemonCore.Store.put(:cron_settings, :global_pause, :garbage)
    assert {:ok, %{paused_at_ms: nil}} = CronStore.global_pause()
    assert {:ok, %{paused: true, paused_at_ms: nil}} = CronManager.pause_status()
  end

  # Mirrors a restart while paused: the marker exists before the manager loads.
  defp paused_state(ids) do
    {:ok, %{paused_at_ms: paused_at}} = CronManager.pause_all()
    {:ok, state} = CronManager.init([])
    {%{state | jobs: Map.take(state.jobs, ids)}, paused_at}
  end

  defp pause_check(checks), do: Enum.find(checks, &(&1.name == "automation.cron_paused"))

  defp pending_retry(job_id, due_at_ms: due_at_ms) do
    run = job_id |> CronRun.new(:schedule) |> CronRun.fail("boom")

    run = %{
      run
      | meta: %{retry_due_at_ms: due_at_ms, retry_next_attempt: 1, retry_root_id: run.id}
    }

    CronStore.put_run(run)
    run
  end

  defp store_job(id, attrs) do
    job =
      CronJob.new(
        Map.merge(
          %{
            id: id,
            name: id,
            schedule: "0 9 * * *",
            timezone: "UTC",
            agent_id: "test",
            session_key: "agent:test:main",
            prompt: "test"
          },
          Map.new(attrs)
        )
      )

    job = %{job | next_run_at_ms: Keyword.get(attrs, :next_run_at_ms)}
    CronStore.put_job(job)
    job
  end

  defp from, do: {self(), make_ref()}

  defp call_tool(tool, params), do: tool.execute.("call_1", params, nil, nil)

  defp await(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && await(fun, attempts - 1)
    end
  end
end
