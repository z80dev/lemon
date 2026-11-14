defmodule LemonAutomation.CronManagerWakeTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}

  defmodule TestSubmitter do
    @moduledoc false

    def submit(_job, _run, _opts), do: {:ok, "wake completed"}
  end

  setup do
    previous_submitter = Application.get_env(:lemon_automation, :cron_run_submitter)
    Application.put_env(:lemon_automation, :cron_run_submitter, TestSubmitter)

    ensure_store_started()
    ensure_cron_manager_started()

    token = System.unique_integer([:positive, :monotonic])

    on_exit(fn -> restore_env(:cron_run_submitter, previous_submitter) end)
    on_exit(fn -> cleanup_fixtures(token) end)

    {:ok, token: token}
  end

  describe "wake/2" do
    test "returns {:error, :not_found} for unknown job", %{token: token} do
      assert {:error, :not_found} = CronManager.wake("wake_missing_#{token}")
    end

    test "returns {:error, :job_disabled} for disabled job", %{token: token} do
      job = build_job(token, "disabled", enabled: false)
      :ok = CronStore.put_job(job)

      assert {:error, :job_disabled} = CronManager.wake(job.id)
    end

    test "returns {:error, :already_running} when skip_if_running and active run exists", %{
      token: token
    } do
      job = build_job(token, "running_guard")
      :ok = CronStore.put_job(job)
      :ok = CronStore.put_run(build_active_run(token, "running_guard", job.id))

      assert {:error, :already_running} = CronManager.wake(job.id, skip_if_running: true)
    end

    test "returns wake-triggered run and merges context into run meta", %{token: token} do
      job = build_job(token, "success")
      :ok = CronStore.put_job(job)

      context = %{reason: "manual test", source: "wake_test"}

      assert {:ok, run} = CronManager.wake(job.id, context: context)
      assert run.job_id == job.id
      assert is_binary(run.run_id) and run.run_id != ""
      assert run.triggered_by == :wake
      assert run.meta.wake_context == context

      assert persisted_run = CronStore.get_run(run.id)
      assert persisted_run.triggered_by == :wake
      assert persisted_run.meta.wake_context == context

      # Wait for the async wake task and its manager ownership to be released.
      assert %CronRun{status: :completed, output: "wake completed"} = await_terminal_run(run.id)
      _ = :sys.get_state(CronManager)
    end
  end

  defp cleanup_fixtures(token) do
    prefix = "wake_job_#{token}_"
    managed_jobs = if Process.whereis(CronManager), do: CronManager.list(), else: []

    job_ids =
      (managed_jobs ++ CronStore.list_jobs())
      |> Enum.map(& &1.id)
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.uniq()

    Enum.each(job_ids, fn job_id ->
      if Process.whereis(CronManager), do: CronManager.remove(job_id)
      _ = CronStore.delete_job(job_id)

      for run <- CronStore.list_runs(job_id, limit: 10_000), do: CronStore.delete_run(run.id)

      for event <- CronStore.list_audit_events(job_id: job_id, limit: 10_000) do
        CronStore.delete_audit_event(event.id)
      end
    end)
  end

  defp job_id(token, suffix), do: "wake_job_#{token}_#{suffix}"
  defp run_id(token, suffix), do: "wake_run_#{token}_#{suffix}"

  defp build_job(token, suffix, attrs \\ []) do
    base = %CronJob{
      id: job_id(token, suffix),
      name: "Wake job #{suffix}",
      schedule: "* * * * *",
      enabled: true,
      agent_id: "wake_agent_#{token}",
      session_key: "agent:wake_agent_#{token}:main",
      prompt: "Wake prompt #{suffix}",
      timezone: "UTC",
      jitter_sec: 0,
      timeout_ms: 300_000,
      created_at_ms: 1_000,
      updated_at_ms: 1_000,
      last_run_at_ms: nil,
      next_run_at_ms: nil,
      meta: %{source: "wake_test"}
    }

    struct!(base, Map.new(attrs))
  end

  defp build_active_run(token, suffix, job_id) do
    %CronRun{
      id: run_id(token, suffix),
      job_id: job_id,
      run_id: "router_#{token}_#{suffix}",
      status: :running,
      started_at_ms: 2_000,
      completed_at_ms: nil,
      duration_ms: nil,
      triggered_by: :schedule,
      error: nil,
      output: nil,
      suppressed: false,
      meta: %{source: "wake_test"}
    }
  end

  defp await_terminal_run(run_id, attempts \\ 500)

  defp await_terminal_run(_run_id, 0) do
    flunk("wake run did not reach terminal state before timeout")
  end

  defp await_terminal_run(run_id, attempts) do
    case CronStore.get_run(run_id) do
      %CronRun{status: status} = run when status in [:completed, :failed, :timeout] ->
        run

      _ ->
        Process.sleep(10)
        await_terminal_run(run_id, attempts - 1)
    end
  end

  defp ensure_store_started do
    if is_nil(Process.whereis(LemonCore.Store)) do
      case start_supervised(LemonCore.Store) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp ensure_cron_manager_started do
    if is_nil(Process.whereis(LemonAutomation.CronManager)) do
      case start_supervised(LemonAutomation.CronManager) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_automation, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_automation, key, value)
end
