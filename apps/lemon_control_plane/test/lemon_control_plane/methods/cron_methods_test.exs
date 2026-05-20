defmodule LemonControlPlane.Methods.CronMethodsTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.CronManager
  alias LemonAutomation.{CronRun, CronStore}

  alias LemonControlPlane.Methods.{
    CronAbort,
    CronAdd,
    CronAudit,
    CronList,
    CronPause,
    CronRemove,
    CronResume,
    CronStatus,
    CronUpdate
  }

  alias LemonControlPlane.Methods.CronRun, as: CronRunMethod
  alias LemonControlPlane.Methods.CronRuns, as: CronRunsMethod

  setup do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "cp-cron-update-#{token}",
        schedule: "0 0 1 1 *",
        enabled: false,
        agent_id: "cp_agent_#{token}",
        session_key: "agent:cp_agent_#{token}:main",
        prompt: "ping",
        timezone: "UTC"
      })

    on_exit(fn ->
      _ = CronManager.remove(job.id)
    end)

    {:ok, job: job}
  end

  test "cron.update rejects sessionKey patch", %{job: job} do
    assert {:error, {:invalid_request, msg, nil}} =
             CronUpdate.handle(
               %{"id" => job.id, "sessionKey" => "agent:other:main", "enabled" => true},
               %{}
             )

    assert msg =~ "Immutable fields cannot be updated"
    assert msg =~ "session_key"
  end

  test "cron.update rejects agentId patch", %{job: job} do
    assert {:error, {:invalid_request, msg, nil}} =
             CronUpdate.handle(%{"id" => job.id, "agentId" => "other"}, %{})

    assert msg =~ "Immutable fields cannot be updated"
    assert msg =~ "agent_id"
  end

  test "cron.update still updates mutable fields", %{job: job} do
    assert {:ok, %{"id" => id, "updated" => true, "summary" => update_summary}} =
             CronUpdate.handle(
               %{
                 "id" => job.id,
                 "enabled" => true,
                 "timezone" => "UTC",
                 "maxRetries" => 2,
                 "retryBackoffMs" => 5_000
               },
               %{}
             )

    assert id == job.id
    assert "max_retries" in update_summary["changedFields"]
    assert update_summary["targetTextReturned"] == false
    assert update_summary["cleanup"]["includesPromptText"] == false
    updated = CronManager.list() |> Enum.find(&(&1.id == job.id))
    assert updated.max_retries == 2
    assert updated.retry_backoff_ms == 5_000
  end

  test "cron.update returns invalid_request for invalid schedule updates", %{job: job} do
    assert {:error, {:invalid_request, msg, nil}} =
             CronUpdate.handle(%{"id" => job.id, "schedule" => "every 45m"}, %{})

    assert msg =~ "Invalid schedule"
    assert msg =~ "Minute interval must evenly divide 60"
  end

  test "cron.add normalizes supported schedule shorthands" do
    token = System.unique_integer([:positive, :monotonic])

    assert {:ok,
            %{
              "id" => id,
              "schedule" => "0 8 * * 1",
              "timezone" => "UTC",
              "summary" => add_summary
            }} =
             CronAdd.handle(
               %{
                 "name" => "cp natural cron #{token}",
                 "schedule" => "weekly monday at 8am",
                 "agentId" => "cp_natural_#{token}",
                 "sessionKey" => "agent:cp_natural_#{token}:main",
                 "prompt" => "ping"
               },
               %{}
             )

    assert add_summary["promptBytes"] == byte_size("ping")
    assert add_summary["targetTextReturned"] == false
    assert add_summary["cleanup"]["includesPromptText"] == false
    assert Enum.find(CronManager.list(), &(&1.id == id)).schedule == "0 8 * * 1"

    _ = CronManager.remove(id)
  end

  test "cron.list redacts target text by default and exposes byte summaries", %{job: job} do
    assert {:ok, %{"jobs" => jobs, "summary" => summary}} = CronList.handle(%{}, %{})

    listed = Enum.find(jobs, &(&1["id"] == job.id))
    assert listed["prompt"] == nil
    assert listed["command"] == nil
    assert listed["promptBytes"] == byte_size("ping")
    assert listed["summary"]["targetTextReturned"] == false
    assert listed["summary"]["cleanup"]["includesPromptText"] == false
    assert summary["jobCount"] == length(jobs)
    assert summary["targetTextReturned"] == false
    assert summary["cleanup"]["includesCommandText"] == false

    assert {:ok, %{"jobs" => raw_jobs, "summary" => raw_summary}} =
             CronList.handle(%{"includeTargetText" => true}, %{})

    raw_listed = Enum.find(raw_jobs, &(&1["id"] == job.id))
    assert raw_listed["prompt"] == "ping"
    assert raw_listed["command"] == nil
    assert raw_listed["summary"]["targetTextReturned"] == true
    assert raw_summary["targetTextReturned"] == true
    assert raw_summary["cleanup"]["includesPromptText"] == true
  end

  test "cron.add creates operator command jobs without agent routing" do
    token = System.unique_integer([:positive, :monotonic])

    assert {:ok,
            %{
              "id" => id,
              "mode" => "command",
              "schedule" => "0 * * * *",
              "timezone" => "UTC",
              "summary" => command_summary
            }} =
             CronAdd.handle(
               %{
                 "name" => "cp command cron #{token}",
                 "schedule" => "hourly",
                 "command" => "printf cp-command-ok"
               },
               %{}
             )

    assert command_summary["mode"] == "command"
    assert command_summary["commandBytes"] == byte_size("printf cp-command-ok")
    assert command_summary["cleanup"]["includesCommandText"] == false
    job = Enum.find(CronManager.list(), &(&1.id == id))
    assert job.agent_id == nil
    assert job.session_key == nil
    assert job.command == "printf cp-command-ok"

    _ = CronManager.remove(id)
  end

  test "cron.update updates command job target fields" do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, command_job} =
      CronManager.add(%{
        name: "cp command update #{token}",
        schedule: "hourly",
        enabled: false,
        command: "printf before"
      })

    assert {:ok, %{"id" => id, "updated" => true, "summary" => command_update_summary}} =
             CronUpdate.handle(
               %{
                 "id" => command_job.id,
                 "command" => " printf after ",
                 "cwd" => File.cwd!(),
                 "env" => %{"LEMON_CRON_TEST" => "1"}
               },
               %{}
             )

    assert id == command_job.id
    assert "command" in command_update_summary["changedFields"]
    assert command_update_summary["commandBytes"] == byte_size("printf after")
    assert command_update_summary["cleanup"]["includesCommandText"] == false
    updated = CronManager.list() |> Enum.find(&(&1.id == command_job.id))
    assert updated.command == "printf after"
    assert updated.cwd == File.cwd!()
    assert updated.env == %{"LEMON_CRON_TEST" => "1"}

    _ = CronManager.remove(command_job.id)
  end

  test "cron.update rejects target type conversion", %{job: job} do
    assert {:error, {:invalid_request, msg, nil}} =
             CronUpdate.handle(%{"id" => job.id, "command" => "printf no"}, %{})

    assert msg == "Command fields can only update command cron jobs"
  end

  test "cron.pause and cron.resume expose explicit lifecycle controls", %{job: job} do
    assert {:ok, %{"id" => id, "paused" => true, "enabled" => false, "summary" => pause_summary}} =
             CronPause.handle(%{"id" => job.id}, %{})

    assert id == job.id
    assert pause_summary["paused"] == true
    assert pause_summary["cleanup"]["includesPromptText"] == false
    assert Enum.find(CronManager.list(), &(&1.id == job.id)).enabled == false

    assert {:ok,
            %{"id" => ^id, "resumed" => true, "enabled" => true, "summary" => resume_summary}} =
             CronResume.handle(%{"id" => job.id}, %{})

    assert resume_summary["resumed"] == true
    assert resume_summary["cleanup"]["includesPromptText"] == false
    assert Enum.find(CronManager.list(), &(&1.id == job.id)).enabled == true
  end

  test "cron.run exposes manual trigger lifecycle summary", %{job: job} do
    assert {:ok,
            %{
              "triggered" => true,
              "jobId" => job_id,
              "runId" => run_id,
              "summary" => summary
            }} = CronRunMethod.handle(%{"id" => job.id}, %{})

    assert job_id == job.id
    assert summary["jobId"] == job.id
    assert summary["runId"] == run_id
    assert summary["triggeredBy"] == "manual"
    assert summary["rawIdsReturned"] == true
    assert summary["cleanup"]["includesPromptText"] == false
    assert summary["cleanup"]["includesOutputText"] == false

    on_exit(fn -> CronStore.delete_run(run_id) end)
  end

  test "cron.remove exposes deletion cleanup summary" do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, removable} =
      CronManager.add(%{
        name: "cp cron remove #{token}",
        schedule: "hourly",
        enabled: false,
        agent_id: "cp_remove_#{token}",
        session_key: "agent:cp_remove_#{token}:main",
        prompt: "remove me"
      })

    assert {:ok, %{"removed" => true, "id" => id, "summary" => summary}} =
             CronRemove.handle(%{"id" => removable.id}, %{})

    assert id == removable.id
    assert summary["jobId"] == removable.id
    assert summary["removed"] == true
    assert summary["rawIdsReturned"] == true
    assert summary["cleanup"]["includesPromptText"] == false
    assert summary["cleanup"]["includesCommandText"] == false
  end

  test "cron.runs exposes run history summaries and cleanup flags", %{job: job} do
    token = System.unique_integer([:positive, :monotonic])
    completed_id = "cp_cron_runs_completed_#{token}"
    failed_id = "cp_cron_runs_failed_#{token}"

    completed =
      job.id
      |> CronRun.new(:manual)
      |> Map.put(:id, completed_id)
      |> CronRun.start("cp_cron_runs_router_completed")
      |> CronRun.complete("cron output body api_key=test123")

    failed =
      job.id
      |> CronRun.new(:retry)
      |> Map.put(:id, failed_id)
      |> CronRun.start("cp_cron_runs_router_failed")
      |> CronRun.fail("cron error body Bearer abc.def")

    CronStore.put_run(completed)
    CronStore.put_run(failed)

    on_exit(fn ->
      CronStore.delete_run(completed_id)
      CronStore.delete_run(failed_id)
    end)

    assert {:ok, %{"runs" => runs, "summary" => summary}} =
             CronRunsMethod.handle(%{"id" => job.id, "limit" => 10}, %{})

    listed = Enum.find(runs, &(&1["id"] == completed_id))
    assert listed["output"] == "cron output body api_key=[REDACTED]"
    assert listed["summary"]["outputBytes"] == byte_size("cron output body api_key=test123")
    assert listed["summary"]["fullOutputReturned"] == false
    assert listed["summary"]["outputPreviewReturned"] == true
    refute inspect(runs) =~ "test123"
    refute inspect(runs) =~ "abc.def"
    assert summary["runCount"] >= 2
    assert summary["statusCounts"]["completed"] >= 1
    assert summary["statusCounts"]["failed"] >= 1
    assert summary["fullOutputReturned"] == false
    assert summary["outputPreviewReturned"] == true
    assert summary["errorTextReturned"] == true
    assert summary["cleanup"]["includesOutputText"] == true
    assert summary["cleanup"]["includesFullOutputText"] == false
    assert summary["cleanup"]["includesErrorText"] == true
    assert summary["cleanup"]["redactsSensitiveOutputValues"] == true
    assert summary["cleanup"]["includesMessageBodies"] == false

    assert {:ok, %{"summary" => full_summary}} =
             CronRunsMethod.handle(
               %{
                 "id" => job.id,
                 "limit" => 10,
                 "includeOutput" => true,
                 "includeRunRecord" => true,
                 "includeIntrospection" => true
               },
               %{}
             )

    assert full_summary["fullOutputReturned"] == true
    assert full_summary["runRecordReturned"] == true
    assert full_summary["introspectionReturned"] == true
    assert full_summary["cleanup"]["includesFullOutputText"] == true
    assert full_summary["cleanup"]["includesMessageBodies"] == true
  end

  test "cron.abort exposes active run cancellation", %{job: job} do
    run =
      job.id
      |> CronRun.new(:manual)
      |> Map.put(:id, "cp_cron_abort_run_#{System.unique_integer([:positive])}")
      |> CronRun.start("cp_router_run")

    CronStore.put_run(run)

    assert {:ok,
            %{
              "aborted" => true,
              "runId" => run_id,
              "jobId" => job_id,
              "status" => "aborted",
              "routerRunId" => "cp_router_run",
              "summary" => abort_summary
            }} = CronAbort.handle(%{"runId" => run.id}, %{})

    assert run_id == run.id
    assert job_id == job.id
    assert abort_summary["rawIdsReturned"] == true
    assert abort_summary["cleanup"]["includesOutputText"] == false
    assert abort_summary["cleanup"]["includesErrorText"] == false
    assert CronStore.get_run(run.id).status == :aborted
  end

  test "cron.status exposes scheduler lock, retry, and recovery counters", %{job: job} do
    token = System.unique_integer([:positive, :monotonic])
    active_run_id = "cp_cron_status_active_#{token}"
    failed_run_id = "cp_cron_status_failed_#{token}"

    active_run =
      job.id
      |> CronRun.new(:schedule)
      |> Map.put(:id, active_run_id)
      |> CronRun.start("cp_cron_status_router_active")

    failed_run =
      job.id
      |> CronRun.new(:retry)
      |> Map.put(:id, failed_run_id)
      |> Map.put(:meta, %{retry_attempt: 1, retry_root_id: active_run_id})
      |> CronRun.start("cp_cron_status_router_failed")
      |> CronRun.fail("failed for status")

    CronStore.put_run(active_run)
    CronStore.put_run(failed_run)

    suppressed =
      CronStore.record_audit(:scheduled_run_suppressed, %{
        job_id: job.id,
        source: :test,
        triggered_by: :schedule,
        reason: :active_run_exists
      })

    stale =
      CronStore.record_audit(:stale_run_recovered, %{
        job_id: job.id,
        run_id: active_run_id,
        source: :test,
        status: :timeout,
        triggered_by: :schedule
      })

    retry =
      CronStore.record_audit(:retry_scheduled, %{
        job_id: job.id,
        run_id: failed_run_id,
        source: :test,
        status: :failed,
        triggered_by: :schedule
      })

    on_exit(fn ->
      CronStore.delete_run(active_run_id)
      CronStore.delete_run(failed_run_id)
      CronStore.delete_audit_event(suppressed.id)
      CronStore.delete_audit_event(stale.id)
      CronStore.delete_audit_event(retry.id)
    end)

    assert {:ok, status} = CronStatus.handle(%{}, %{})

    assert status["activeRunCount"] >= 1
    assert status["failedRunCount"] >= 1
    assert status["retryRunCount"] >= 1
    assert status["suppressedSlotCount"] >= 1
    assert status["staleRecoveryCount"] >= 1
    assert status["retryScheduledCount"] >= 1
    assert status["runStatusCounts"]["running"] >= 1
    assert status["runStatusCounts"]["failed"] >= 1
    assert status["triggerCounts"]["retry"] >= 1
    assert status["auditActionCounts"]["scheduled_run_suppressed"] >= 1
    assert status["auditActionCounts"]["stale_run_recovered"] >= 1
    assert status["auditActionCounts"]["retry_scheduled"] >= 1
    assert status["summary"]["activeRunCount"] >= 1
    assert status["summary"]["failedRunCount"] >= 1
    assert status["summary"]["retryRunCount"] >= 1
    assert status["summary"]["cleanup"]["includesPromptText"] == false
    assert status["summary"]["cleanup"]["includesCommandText"] == false
    assert status["summary"]["cleanup"]["includesOutputText"] == false
    assert status["summary"]["cleanup"]["includesErrorText"] == false
  end

  test "cron.audit exposes durable lifecycle history", %{job: job} do
    event =
      CronStore.record_audit(:run_aborted, %{
        job_id: job.id,
        run_id: "cp_cron_audit_run_#{System.unique_integer([:positive])}",
        router_run_id: "cp_cron_audit_router",
        source: :test,
        status: :aborted,
        triggered_by: :manual,
        reason: "operator requested",
        changed_fields: [:enabled]
      })

    assert {:ok, %{"events" => [payload], "total" => 1, "summary" => summary}} =
             CronAudit.handle(%{"jobId" => job.id, "action" => "run_aborted"}, %{})

    assert payload["id"] == event.id
    assert payload["jobId"] == job.id
    assert payload["runId"] == event.run_id
    assert payload["routerRunId"] == "cp_cron_audit_router"
    assert payload["action"] == "run_aborted"
    assert payload["status"] == "aborted"
    assert payload["triggeredBy"] == "manual"
    assert payload["changedFields"] == ["enabled"]
    assert summary["eventCount"] == 1
    assert summary["actionCounts"]["run_aborted"] == 1
    assert summary["filteredByJobId"] == true
    assert summary["filteredByAction"] == true
    assert summary["rawIdsReturned"] == true
    assert summary["reasonTextReturned"] == true
    assert summary["cleanup"]["includesPromptText"] == false
    assert summary["cleanup"]["includesCommandText"] == false
    assert summary["cleanup"]["includesOutputText"] == false
    assert summary["cleanup"]["includesErrorText"] == false
  end
end
