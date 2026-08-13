defmodule LemonAutomation.CronManagerMonitorTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}
  alias LemonCore.{Bus, Event}

  defmodule MonitorSubmitter do
    @moduledoc false

    def submit(job, run, _opts) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      output = :persistent_term.get({__MODULE__, :output})
      send(test_pid, {:cron_submit, job.id, run.id, run.triggered_by})
      {:ok, output}
    end
  end

  setup do
    previous = Application.get_env(:lemon_automation, :cron_run_submitter)
    Application.put_env(:lemon_automation, :cron_run_submitter, MonitorSubmitter)
    :persistent_term.put({MonitorSubmitter, :test_pid}, self())
    :persistent_term.put({MonitorSubmitter, :output}, "state: green")

    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cron_monitor_mgr_#{token}"
    base_session_key = "agent:#{agent_id}:main"

    {:ok, job} =
      CronManager.add(%{
        name: "monitor-test-#{token}",
        schedule: "* * * * *",
        agent_id: agent_id,
        session_key: base_session_key,
        prompt: "watch it",
        timezone: "UTC",
        monitor: true
      })

    topic = Bus.session_topic(base_session_key)
    Bus.subscribe(topic)
    Bus.subscribe("cron")

    on_exit(fn ->
      Bus.unsubscribe(topic)
      Bus.unsubscribe("cron")

      if is_nil(previous) do
        Application.delete_env(:lemon_automation, :cron_run_submitter)
      else
        Application.put_env(:lemon_automation, :cron_run_submitter, previous)
      end

      :persistent_term.erase({MonitorSubmitter, :test_pid})
      :persistent_term.erase({MonitorSubmitter, :output})

      for run <- CronStore.list_runs(job.id, limit: 200), do: CronStore.delete_run(run.id)
      for event <- audit_events(job.id), do: CronStore.delete_audit_event(event.id)

      _ = CronManager.remove(job.id)
      CronStore.delete_monitor_state(job.id)
    end)

    {:ok, token: token, job: job, base_session_key: base_session_key}
  end

  test "unchanged output is suppressed and changed output delivers again", %{job: job} do
    # Run 1 — baseline, delivers.
    first_run_id = dispatch(job, 1)
    assert_receive {:cron_submit, _job_id, ^first_run_id, :schedule}, 5_000
    assert_receive %Event{type: :run_completed, meta: %{cron_run_id: ^first_run_id}}, 5_000

    assert await(fn -> completed?(first_run_id) end)
    refute CronStore.get_run(first_run_id).suppressed
    assert "monitor_baseline_recorded" in audit_actions(job.id)

    flush_events()

    # Run 2 — same output, suppressed.
    second_run_id = dispatch(job, 2)
    assert_receive {:cron_submit, _job_id, ^second_run_id, :schedule}, 5_000

    assert_receive %Event{
                     type: :cron_run_completed,
                     payload: %{cron_run_id: ^second_run_id, suppressed: true}
                   },
                   5_000

    refute_receive %Event{type: :run_completed, meta: %{cron_run_id: ^second_run_id}}, 300

    assert CronStore.get_run(second_run_id).suppressed == true
    assert "monitor_output_unchanged" in audit_actions(job.id)

    flush_events()

    # Run 3 — changed output, delivers.
    :persistent_term.put({MonitorSubmitter, :output}, "state: red")
    third_run_id = dispatch(job, 3)
    assert_receive {:cron_submit, _job_id, ^third_run_id, :schedule}, 5_000
    assert_receive %Event{type: :run_completed, meta: %{cron_run_id: ^third_run_id}}, 5_000

    assert await(fn -> completed?(third_run_id) end)
    refute CronStore.get_run(third_run_id).suppressed
    assert "monitor_output_changed" in audit_actions(job.id)
  end

  test "manual runs deliver even when the output is unchanged", %{job: job} do
    first_run_id = dispatch(job, 1)
    assert_receive {:cron_submit, _job_id, ^first_run_id, :schedule}, 5_000
    assert await(fn -> completed?(first_run_id) end)

    flush_events()

    assert {:ok, %CronRun{id: manual_run_id}} = CronManager.run_now(job.id)
    assert_receive {:cron_submit, _job_id, ^manual_run_id, :manual}, 5_000
    assert_receive %Event{type: :run_completed, meta: %{cron_run_id: ^manual_run_id}}, 5_000

    assert await(fn -> completed?(manual_run_id) end)
    refute CronStore.get_run(manual_run_id).suppressed
  end

  test "suppression state survives a CronManager restart", %{job: job} do
    first_run_id = dispatch(job, 1)
    assert_receive {:cron_submit, _job_id, ^first_run_id, :schedule}, 5_000
    assert await(fn -> completed?(first_run_id) end)

    old_pid = Process.whereis(CronManager)
    GenServer.stop(CronManager)

    assert await(fn ->
             pid = Process.whereis(CronManager)
             is_pid(pid) and pid != old_pid
           end)

    flush_events()

    second_run_id = dispatch(job, 2)
    assert_receive {:cron_submit, _job_id, ^second_run_id, :schedule}, 5_000

    assert await(fn ->
             match?(
               %CronRun{status: :completed, suppressed: true},
               CronStore.get_run(second_run_id)
             )
           end)

    refute_receive %Event{type: :run_completed, meta: %{cron_run_id: ^second_run_id}}, 300
  end

  test "removing the job clears its monitor state", %{job: job} do
    first_run_id = dispatch(job, 1)
    assert_receive {:cron_submit, _job_id, ^first_run_id, :schedule}, 5_000
    assert await(fn -> completed?(first_run_id) end)
    assert CronStore.get_monitor_state(job.id) != nil

    assert :ok = CronManager.remove(job.id)
    assert CronStore.get_monitor_state(job.id) == nil
  end

  # Forces the job due at a distinct scheduled slot so each tick claims a fresh
  # deterministic run id.
  defp dispatch(%CronJob{} = job, nth) do
    scheduled_for_ms = LemonCore.Clock.now_ms() - nth * 120_000
    stored = CronStore.get_job(job.id) || job
    due = %{stored | next_run_at_ms: scheduled_for_ms, enabled: true}

    CronStore.put_job(due)
    :sys.replace_state(CronManager, fn state -> put_in(state.jobs[job.id], due) end)

    CronManager.tick()
    CronStore.scheduled_run_id(job.id, scheduled_for_ms)
  end

  defp completed?(run_id) do
    match?(%CronRun{status: :completed}, CronStore.get_run(run_id))
  end

  defp audit_events(job_id), do: CronStore.list_audit_events(job_id: job_id, limit: 200)

  defp audit_actions(job_id), do: Enum.map(audit_events(job_id), & &1.action)

  defp flush_events do
    receive do
      %Event{} -> flush_events()
    after
      0 -> :ok
    end
  end

  defp await(fun, attempts \\ 200)

  defp await(_fun, 0), do: false

  defp await(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      await(fun, attempts - 1)
    end
  end
end
