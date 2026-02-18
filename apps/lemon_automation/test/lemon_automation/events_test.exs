defmodule LemonAutomation.EventsTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronRun, Events}
  alias LemonCore.{Bus, Event}

  setup do
    Bus.subscribe("cron")
    flush_events()

    on_exit(fn ->
      Bus.unsubscribe("cron")
    end)

    :ok
  end

  defp flush_events do
    receive do
      %Event{} -> flush_events()
    after
      0 -> :ok
    end
  end

  defp sample_job(unique) do
    CronJob.new(%{
      id: "cron_evt_#{unique}",
      name: "Cron Event #{unique}",
      schedule: "* * * * *",
      agent_id: "agent_evt_#{unique}",
      session_key: "agent:agent_evt_#{unique}:main",
      prompt: "prompt #{unique}"
    })
  end

  defp sample_run(job_id, unique, attrs \\ %{}) do
    run = %CronRun{
      id: "run_evt_#{unique}",
      job_id: job_id,
      run_id: "router_evt_#{unique}",
      status: :running,
      started_at_ms: 10_000,
      completed_at_ms: nil,
      duration_ms: nil,
      triggered_by: :manual,
      error: nil,
      output: nil,
      suppressed: false,
      meta: %{source: "events_test"}
    }

    struct!(run, attrs)
  end

  test "emit_tick/1 emits cron_tick on cron topic" do
    timestamp_ms = 1_700_000_000_123
    Events.emit_tick(timestamp_ms)

    assert_receive %Event{
                     type: :cron_tick,
                     payload: %{timestamp_ms: ^timestamp_ms},
                     meta: nil,
                     ts_ms: ts_ms
                   },
                   500

    assert is_integer(ts_ms)
  end

  test "emit_job_created/1 emits cron_job_created with job and meta" do
    unique = System.unique_integer([:positive])
    job = sample_job(unique)

    job_id = job.id
    agent_id = job.agent_id
    job_name = job.name
    session_key = job.session_key

    Events.emit_job_created(job)

    assert_receive %Event{
                     type: :cron_job_created,
                     payload: %{
                       job: %{
                         id: ^job_id,
                         agent_id: ^agent_id,
                         name: ^job_name,
                         session_key: ^session_key
                       }
                     },
                     meta: %{job_id: ^job_id, agent_id: ^agent_id},
                     ts_ms: ts_ms
                   },
                   500

    assert is_integer(ts_ms)
  end

  test "run lifecycle events include expected payload and meta fields" do
    unique = System.unique_integer([:positive])
    job = sample_job(unique)
    run = sample_run(job.id, unique, %{triggered_by: :wake})

    run_id = run.id
    job_id = job.id
    agent_id = job.agent_id
    job_name = job.name
    session_key = job.session_key
    router_run_id = run.run_id

    Events.emit_run_started(run, job)

    assert_receive %Event{
                     type: :cron_run_started,
                     payload: %{
                       run: %{id: ^run_id, job_id: ^job_id, run_id: ^router_run_id},
                       job_name: ^job_name,
                       agent_id: ^agent_id,
                       triggered_by: :wake
                     },
                     meta: %{
                       job_id: ^job_id,
                       run_id: ^run_id,
                       agent_id: ^agent_id,
                       session_key: ^session_key
                     },
                     ts_ms: started_ts_ms
                   },
                   500

    assert is_integer(started_ts_ms)

    output = "ok-#{unique}"

    completed_run =
      struct!(run, %{
        status: :completed,
        completed_at_ms: 10_050,
        duration_ms: 50,
        output: output,
        suppressed: true
      })

    Events.emit_run_completed(completed_run)

    assert_receive %Event{
                     type: :cron_run_completed,
                     payload: %{
                       run: %{id: ^run_id, job_id: ^job_id, status: :completed, output: ^output},
                       status: :completed,
                       duration_ms: 50,
                       output: ^output,
                       error: nil,
                       suppressed: true
                     },
                     meta: %{job_id: ^job_id, run_id: ^run_id},
                     ts_ms: completed_ts_ms
                   },
                   500

    assert is_integer(completed_ts_ms)
  end

  test "emit_heartbeat_alert/3 emits heartbeat_alert with ids in payload and meta" do
    unique = System.unique_integer([:positive])
    job = sample_job(unique)
    run = sample_run(job.id, unique)
    response = "not-ok-#{unique}"

    run_id = run.id
    job_id = job.id
    job_name = job.name
    agent_id = job.agent_id

    Events.emit_heartbeat_alert(run, job, response)

    assert_receive %Event{
                     type: :heartbeat_alert,
                     payload: %{
                       run_id: ^run_id,
                       job_id: ^job_id,
                       job_name: ^job_name,
                       agent_id: ^agent_id,
                       response: ^response,
                       severity: :warning
                     },
                     meta: %{job_id: ^job_id, run_id: ^run_id, agent_id: ^agent_id},
                     ts_ms: ts_ms
                   },
                   500

    assert is_integer(ts_ms)
  end

  test "emit_heartbeat_alert/3 accepts map run payloads" do
    unique = System.unique_integer([:positive])
    job = sample_job(unique)
    run = CronRun.to_map(sample_run(job.id, unique))
    response = "map-not-ok-#{unique}"

    run_id = run[:id]
    job_id = job.id
    job_name = job.name
    agent_id = job.agent_id

    Events.emit_heartbeat_alert(run, job, response)

    assert_receive %Event{
                     type: :heartbeat_alert,
                     payload: %{
                       run_id: ^run_id,
                       job_id: ^job_id,
                       job_name: ^job_name,
                       agent_id: ^agent_id,
                       response: ^response,
                       severity: :warning
                     },
                     meta: %{job_id: ^job_id, run_id: ^run_id, agent_id: ^agent_id},
                     ts_ms: ts_ms
                   },
                   500

    assert is_integer(ts_ms)
  end
end
