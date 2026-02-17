defmodule LemonAutomation.WakeTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronRun, CronStore, Wake}
  alias LemonCore.Store

  @jobs_table :cron_jobs
  @runs_table :cron_runs

  setup do
    clear_table(@jobs_table)
    clear_table(@runs_table)

    {:ok, token: System.unique_integer([:positive, :monotonic])}
  end

  describe "trigger/2" do
    test "returns {:error, :not_found} for unknown job", %{token: token} do
      assert {:error, :not_found} = Wake.trigger("wake_missing_#{token}")
    end

    test "returns {:error, :job_disabled} for disabled job", %{token: token} do
      job = build_job(token, "disabled", enabled: false)
      :ok = CronStore.put_job(job)

      assert {:error, :job_disabled} = Wake.trigger(job.id)
    end

    test "returns {:error, :already_running} when skip_if_running and active run exists", %{
      token: token
    } do
      job = build_job(token, "running_guard")
      :ok = CronStore.put_job(job)
      :ok = CronStore.put_run(build_active_run(token, "running_guard", job.id))

      assert {:error, :already_running} = Wake.trigger(job.id, skip_if_running: true)
    end

    test "returns wake-triggered run and merges context into run meta", %{token: token} do
      job = build_job(token, "success")
      :ok = CronStore.put_job(job)

      context = %{reason: "manual test", source: "wake_test"}

      assert {:ok, run} = Wake.trigger(job.id, context: context)
      assert run.job_id == job.id
      assert run.triggered_by == :wake
      assert run.meta.wake_context == context

      assert persisted_run = CronStore.get_run(run.id)
      assert persisted_run.triggered_by == :wake
      assert persisted_run.meta.wake_context == context

      # Wait for async wake task to complete so it doesn't leak into later suites.
      assert %CronRun{} = await_terminal_run(run.id)
    end
  end

  describe "trigger_many/2" do
    test "aggregates results for each job id", %{token: token} do
      running_job = build_job(token, "many_running")
      disabled_job = build_job(token, "many_disabled", enabled: false)
      missing_id = job_id(token, "many_missing")

      :ok = CronStore.put_job(running_job)
      :ok = CronStore.put_job(disabled_job)
      :ok = CronStore.put_run(build_active_run(token, "many_running", running_job.id))

      results =
        Wake.trigger_many([running_job.id, disabled_job.id, missing_id], skip_if_running: true)

      assert Map.keys(results) |> Enum.sort() == [disabled_job.id, missing_id, running_job.id]
      assert results[running_job.id] == {:error, :already_running}
      assert results[disabled_job.id] == {:error, :job_disabled}
      assert results[missing_id] == {:error, :not_found}
    end
  end

  describe "trigger_matching/2" do
    test "matches case-insensitively and includes only enabled jobs", %{token: token} do
      pattern_stem = "WakePattern#{token}"
      search_pattern = "wAkEpAtTeRn#{token}"

      enabled_lower =
        build_job(token, "matching_lower", name: "checks #{String.downcase(pattern_stem)}")

      enabled_upper =
        build_job(token, "matching_upper", name: "checks #{String.upcase(pattern_stem)}")

      disabled_match =
        build_job(token, "matching_disabled",
          enabled: false,
          name: "checks #{String.downcase(pattern_stem)} disabled"
        )

      enabled_non_match = build_job(token, "non_match", name: "checks other text")

      Enum.each(
        [enabled_lower, enabled_upper, disabled_match, enabled_non_match],
        &CronStore.put_job/1
      )

      :ok = CronStore.put_run(build_active_run(token, "matching_lower", enabled_lower.id))
      :ok = CronStore.put_run(build_active_run(token, "matching_upper", enabled_upper.id))

      results = Wake.trigger_matching(search_pattern, skip_if_running: true)

      assert Map.keys(results) |> Enum.sort() == [enabled_lower.id, enabled_upper.id]
      assert results[enabled_lower.id] == {:error, :already_running}
      assert results[enabled_upper.id] == {:error, :already_running}
      refute Map.has_key?(results, disabled_match.id)
      refute Map.has_key?(results, enabled_non_match.id)
    end
  end

  describe "trigger_for_agent/2" do
    test "includes only enabled jobs for the target agent", %{token: token} do
      target_agent_id = "wake_agent_target_#{token}"
      other_agent_id = "wake_agent_other_#{token}"

      enabled_a = build_job(token, "agent_a", agent_id: target_agent_id)
      enabled_b = build_job(token, "agent_b", agent_id: target_agent_id)

      disabled_target =
        build_job(token, "agent_disabled", agent_id: target_agent_id, enabled: false)

      other_agent = build_job(token, "agent_other", agent_id: other_agent_id)

      Enum.each([enabled_a, enabled_b, disabled_target, other_agent], &CronStore.put_job/1)

      :ok = CronStore.put_run(build_active_run(token, "agent_a", enabled_a.id))
      :ok = CronStore.put_run(build_active_run(token, "agent_b", enabled_b.id))

      results = Wake.trigger_for_agent(target_agent_id, skip_if_running: true)

      assert Map.keys(results) |> Enum.sort() == [enabled_a.id, enabled_b.id]
      assert results[enabled_a.id] == {:error, :already_running}
      assert results[enabled_b.id] == {:error, :already_running}
      refute Map.has_key?(results, disabled_target.id)
      refute Map.has_key?(results, other_agent.id)
    end
  end

  defp clear_table(table) do
    Enum.each(Store.list(table), fn {key, _value} ->
      :ok = Store.delete(table, key)
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

  defp await_terminal_run(run_id, attempts \\ 100)

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
end
