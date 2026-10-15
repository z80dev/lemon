defmodule LemonAutomation.CronManagerUpdateTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronRun, CronStore}

  defmodule AbortRouter do
    def abort_run(id, _reason) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:router_abort, id})
      :persistent_term.get({__MODULE__, :result}, :ok)
    end
  end

  setup do
    previous_router = Application.get_env(:lemon_automation, :cron_router_mod)
    Application.put_env(:lemon_automation, :cron_router_mod, AbortRouter)
    :persistent_term.put({AbortRouter, :test_pid}, self())
    :persistent_term.put({AbortRouter, :result}, :ok)
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "update-test-#{token}",
        schedule: "0 0 1 1 *",
        enabled: false,
        agent_id: "agent_update_#{token}",
        session_key: "agent:agent_update_#{token}:main",
        prompt: "ping",
        timezone: "UTC"
      })

    on_exit(fn ->
      if previous_router,
        do: Application.put_env(:lemon_automation, :cron_router_mod, previous_router),
        else: Application.delete_env(:lemon_automation, :cron_router_mod)

      :persistent_term.erase({AbortRouter, :test_pid})
      :persistent_term.erase({AbortRouter, :result})
      for run <- CronStore.list_runs(job.id), do: CronStore.delete_run(run.id)
      _ = CronManager.remove(job.id)
    end)

    {:ok, job: job}
  end

  test "rejects session_key updates", %{job: job} do
    assert {:error, {:immutable_fields, [:session_key]}} =
             CronManager.update(job.id, %{session_key: "agent:changed:main"})

    assert CronStore.get_job(job.id).session_key == job.session_key
  end

  test "rejects agent_id and session_key updates across key variants", %{job: job} do
    assert {:error, {:immutable_fields, [:agent_id, :session_key]}} =
             CronManager.update(job.id, %{
               "agentId" => "agent_changed",
               "session_key" => "agent:changed:main"
             })

    persisted = CronStore.get_job(job.id)
    assert persisted.agent_id == job.agent_id
    assert persisted.session_key == job.session_key
  end

  test "allows mutable updates", %{job: job} do
    assert {:ok, updated} =
             CronManager.update(job.id, %{
               enabled: true,
               timezone: "America/New_York",
               schedule: "weekdays at 09:30"
             })

    assert updated.enabled == true
    assert updated.timezone == "America/New_York"
    assert updated.schedule == "30 9 * * 1-5"

    assert Enum.any?(CronStore.list_audit_events(job_id: job.id), fn event ->
             event.action == "job_resumed" and
               event.status == "enabled" and
               event.changed_fields == ["enabled", "schedule", "timezone"]
           end)
  end

  test "rejects unknown timezone on creation without persisting a job", %{job: job} do
    id = "invalid_timezone_#{System.unique_integer([:positive, :monotonic])}"

    on_exit(fn -> CronManager.remove(id) end)

    assert {:error, {:invalid_target, "Invalid timezone"}} =
             CronManager.add(%{
               id: id,
               name: "invalid timezone",
               schedule: job.schedule,
               enabled: false,
               agent_id: job.agent_id,
               session_key: job.session_key,
               prompt: "ping",
               timezone: "Not/A_Zone"
             })

    assert CronStore.get_job(id) == nil
  end

  test "rejects invalid timezone patches without changing the existing job", %{job: job} do
    for params <- [%{timezone: "Not/A_Zone"}, %{"timezone" => nil}] do
      assert {:error, {:invalid_target, "Invalid timezone"}} =
               CronManager.update(job.id, params)

      assert CronStore.get_job(job.id) == job
    end
  end

  test "a timezone-only patch changes the next scheduled instant", %{job: job} do
    assert {:ok, updated} =
             CronManager.update(job.id, %{"timezone" => "America/New_York"})

    assert updated.next_run_at_ms != job.next_run_at_ms
    assert updated.schedule == job.schedule

    next = DateTime.from_unix!(updated.next_run_at_ms, :millisecond)
    wall = DateTime.shift_zone!(next, "America/New_York")
    assert {wall.month, wall.day, wall.hour, wall.minute} == {1, 1, 0, 0}
    assert CronStore.get_job(job.id).next_run_at_ms == updated.next_run_at_ms
  end

  test "normalizes schedule shorthands on add" do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "natural schedule #{token}",
        schedule: "daily at 9am",
        enabled: false,
        agent_id: "agent_natural_#{token}",
        session_key: "agent:agent_natural_#{token}:main",
        prompt: "ping",
        timezone: "UTC"
      })

    assert job.schedule == "0 9 * * *"

    _ = CronManager.remove(job.id)
  end

  test "runs operator-owned command jobs without agent routing" do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "command schedule #{token}",
        schedule: "hourly",
        enabled: false,
        command: "printf command-cron-ok",
        timeout_ms: 5_000
      })

    assert job.agent_id == nil
    assert job.session_key == nil
    assert job.prompt == nil
    assert job.command == "printf command-cron-ok"
    assert LemonAutomation.CronJob.execution_mode(job) == :command

    {:ok, run} = CronManager.run_now(job.id)

    assert await(fn ->
             persisted = CronStore.get_run(run.id)

             persisted.status == :completed and persisted.output == "command-cron-ok" and
               persisted.run_id == nil and persisted.meta.mode == :command
           end)

    _ = CronManager.remove(job.id)
  end

  test "updates command job target fields" do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "command update #{token}",
        schedule: "hourly",
        enabled: false,
        command: "printf before",
        timeout_ms: 5_000
      })

    assert {:ok, updated} =
             CronManager.update(job.id, %{
               command: " printf after ",
               cwd: File.cwd!(),
               env: %{"LEMON_CRON_TEST" => "1"}
             })

    assert updated.command == "printf after"
    assert updated.cwd == File.cwd!()
    assert updated.env == %{"LEMON_CRON_TEST" => "1"}

    _ = CronManager.remove(job.id)
  end

  test "rejects target type conversion during update", %{job: job} do
    assert {:error, {:invalid_target, "Command fields can only update command cron jobs"}} =
             CronManager.update(job.id, %{command: "printf no"})

    token = System.unique_integer([:positive, :monotonic])

    {:ok, command_job} =
      CronManager.add(%{
        name: "command reject prompt #{token}",
        schedule: "hourly",
        enabled: false,
        command: "printf before"
      })

    assert {:error, {:invalid_target, "Prompt can only update prompt cron jobs"}} =
             CronManager.update(command_job.id, %{prompt: "no"})

    _ = CronManager.remove(command_job.id)
  end

  test "rejects jobs with both prompt and command targets" do
    assert {:error, {:invalid_target, "Set either prompt or command, not both"}} =
             CronManager.add(%{
               name: "bad mixed target",
               schedule: "hourly",
               agent_id: "agent",
               session_key: "agent:agent:main",
               prompt: "ping",
               command: "echo ping"
             })
  end

  test "aborts active runs and ignores late submitter completion", %{job: job} do
    run =
      job.id
      |> CronRun.new(:manual)
      |> Map.put(:id, "cron_abort_update_#{System.unique_integer([:positive])}")
      |> CronRun.start("router_abort_update")

    CronStore.put_run(run)

    assert {:ok, %CronRun{status: :aborted, error: "Run aborted by operator"}} =
             CronManager.abort_run(run.id)

    assert Enum.any?(CronStore.list_audit_events(run_id: run.id), fn event ->
             event.action == "run_aborted" and
               event.status == "aborted" and
               event.triggered_by == "manual"
           end)

    send(CronManager, {:run_complete, run.id, {:ok, "late success"}})

    assert await(fn ->
             persisted = CronStore.get_run(run.id)
             persisted.status == :aborted and persisted.output == nil
           end)
  end

  test "rejects abort for inactive runs", %{job: job} do
    run =
      job.id
      |> CronRun.new(:manual)
      |> Map.put(:id, "cron_abort_inactive_#{System.unique_integer([:positive])}")
      |> CronRun.start("router_abort_inactive")
      |> CronRun.complete("done")

    CronStore.put_run(run)

    assert {:error, :not_active} = CronManager.abort_run(run.id)
  end

  test "prompt cwd updates preserve prompt mode and normalize the target", %{job: job} do
    assert {:ok, updated} = CronManager.update(job.id, %{"cwd" => "."})
    assert updated.cwd == File.cwd!()
    assert updated.prompt == job.prompt
    assert {:error, {:invalid_target, _}} = CronManager.update(job.id, %{cwd: 42})
  end

  test "unknown abort remains owned, is sent once, and blocks submission claims", %{job: job} do
    :persistent_term.put({AbortRouter, :result}, {:error, :outcome_unknown})
    run = job.id |> CronRun.new(:schedule) |> CronRun.start("router_abort_unknown")
    CronStore.put_run(run)

    assert {:error, :outcome_unknown} = CronManager.abort_run(run.id)
    assert_receive {:router_abort, "router_abort_unknown"}
    assert {:error, :outcome_unknown} = CronManager.abort_run(run.id)
    refute_receive {:router_abort, _}, 50

    assert %CronRun{status: :running, meta: %{outcome_unknown: true, abort_requested: true}} =
             CronStore.get_run(run.id)

    assert {:error, :aborted} =
             GenServer.call(
               CronManager,
               {:claim_submission, run.id, run.run_id, "agent:default:main"}
             )
  end

  defp await(fun, attempts \\ 500)
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
