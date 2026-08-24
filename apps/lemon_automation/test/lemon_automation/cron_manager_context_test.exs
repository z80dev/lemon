defmodule LemonAutomation.CronManagerContextTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore, RunSubmitter}

  defmodule ParamsSubmitter do
    @moduledoc false

    def submit(job, run, opts) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      params = RunSubmitter.build_params(job, run, Keyword.get(opts, :run_id))
      send(test_pid, {:cron_params, job.id, run.id, params})
      {:ok, "ok"}
    end
  end

  setup do
    previous = Application.get_env(:lemon_automation, :cron_run_submitter)
    Application.put_env(:lemon_automation, :cron_run_submitter, ParamsSubmitter)
    :persistent_term.put({ParamsSubmitter, :test_pid}, self())

    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cron_ctx_mgr_#{token}"

    {:ok, source} =
      CronManager.add(%{
        name: "context-source-#{token}",
        schedule: "* * * * *",
        agent_id: agent_id,
        session_key: "agent:#{agent_id}:main",
        prompt: "collect data",
        timezone: "UTC"
      })

    created = [source.id]

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:lemon_automation, :cron_run_submitter)
      else
        Application.put_env(:lemon_automation, :cron_run_submitter, previous)
      end

      :persistent_term.erase({ParamsSubmitter, :test_pid})

      for job <- CronManager.list(),
          String.contains?(job.name, "-#{token}") do
        for run <- CronStore.list_runs(job.id, limit: 200), do: CronStore.delete_run(run.id)
        _ = CronManager.remove(job.id)
      end

      for job_id <- created do
        for run <- CronStore.list_runs(job_id, limit: 200), do: CronStore.delete_run(run.id)
        CronStore.delete_job(job_id)
      end
    end)

    {:ok, token: token, agent_id: agent_id, source: source}
  end

  describe "add validation" do
    test "accepts a valid context_from reference", ctx do
      assert {:ok, %CronJob{context_from: context_from}} =
               CronManager.add(target_attrs(ctx, context_from: ctx.source.id))

      assert context_from == ctx.source.id
    end

    test "rejects an unknown context_from job", ctx do
      assert {:error, {:invalid_target, reason}} =
               CronManager.add(target_attrs(ctx, context_from: "cron_does_not_exist"))

      assert reason =~ "context_from references unknown job cron_does_not_exist"
    end

    test "rejects a self-referencing context_from", ctx do
      self_id = "cron_ctx_self_#{ctx.token}"

      assert {:error, {:invalid_target, reason}} =
               CronManager.add(target_attrs(ctx, id: self_id, context_from: self_id))

      assert reason =~ "cannot reference the job itself"
    end

    test "rejects context_from on a command job", ctx do
      assert {:error, {:invalid_target, reason}} =
               CronManager.add(%{
                 name: "context-command-#{ctx.token}",
                 schedule: "* * * * *",
                 command: "echo hi",
                 context_from: ctx.source.id
               })

      assert reason =~ "prompt cron jobs"
    end

    test "rejects a blank context_from", ctx do
      assert {:error, {:invalid_target, reason}} =
               CronManager.add(target_attrs(ctx, context_from: "   "))

      assert reason =~ "non-empty job id"
    end
  end

  describe "update validation" do
    test "rejects an unknown context_from and accepts a valid one", ctx do
      {:ok, target} = CronManager.add(target_attrs(ctx, []))

      assert {:error, {:invalid_target, _}} =
               CronManager.update(target.id, %{context_from: "cron_missing_#{ctx.token}"})

      assert {:error, {:invalid_target, reason}} =
               CronManager.update(target.id, %{context_from: target.id})

      assert reason =~ "cannot reference the job itself"

      assert {:ok, %CronJob{context_from: linked}} =
               CronManager.update(target.id, %{context_from: ctx.source.id})

      assert linked == ctx.source.id

      assert {:ok, %CronJob{context_from: nil}} =
               CronManager.update(target.id, %{context_from: nil})
    end

    test "rejects non-boolean monitor flags", ctx do
      {:ok, target} = CronManager.add(target_attrs(ctx, []))

      assert {:error, {:invalid_target, reason}} =
               CronManager.update(target.id, %{monitor: "yes"})

      assert reason == "monitor flags must be booleans"

      assert {:error, {:invalid_target, _}} =
               CronManager.update(target.id, %{monitor_notify_first_run: 1})

      assert {:ok, %CronJob{monitor: true, monitor_notify_first_run: false}} =
               CronManager.update(target.id, %{monitor: true, monitor_notify_first_run: false})
    end

    test "normalizes and unpins the model", ctx do
      {:ok, target} = CronManager.add(target_attrs(ctx, []))

      assert {:ok, %CronJob{model: "model-a"}} =
               CronManager.update(target.id, %{model: "  model-a  "})

      assert {:ok, %CronJob{model: nil}} = CronManager.update(target.id, %{model: ""})

      assert {:error, {:invalid_target, reason}} =
               CronManager.update(target.id, %{model: 42})

      assert reason =~ "model must be a string"
    end
  end

  describe "dispatch" do
    test "chained context reaches the submitted prompt", ctx do
      seed_completed_run(ctx.source.id, "SOURCE FINDINGS: 3 alerts")

      {:ok, target} = CronManager.add(target_attrs(ctx, context_from: ctx.source.id))

      assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(target.id)
      target_id = target.id

      assert_receive {:cron_params, ^target_id, ^run_id, params}, 5_000

      assert params.prompt =~ "## Chained Context"
      assert params.prompt =~ "SOURCE FINDINGS: 3 alerts"
      assert params.prompt =~ "summarize the source"
    end

    test "a deleted source degrades to an explicit note and still dispatches", ctx do
      seed_completed_run(ctx.source.id, "SOURCE FINDINGS")
      {:ok, target} = CronManager.add(target_attrs(ctx, context_from: ctx.source.id))

      source_id = ctx.source.id
      assert :ok = CronManager.remove(source_id)
      CronStore.delete_job(source_id)

      assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(target.id)
      target_id = target.id

      assert_receive {:cron_params, ^target_id, ^run_id, params}, 5_000

      assert params.prompt =~ "no longer exists"
      assert params.prompt =~ "summarize the source"
    end
  end

  defp target_attrs(ctx, extra) do
    Map.merge(
      %{
        name: "context-target-#{ctx.token}-#{System.unique_integer([:positive])}",
        schedule: "* * * * *",
        agent_id: ctx.agent_id,
        session_key: "agent:#{ctx.agent_id}:main",
        prompt: "summarize the source",
        timezone: "UTC"
      },
      Map.new(extra)
    )
  end

  defp seed_completed_run(job_id, output) do
    run = %CronRun{
      id: "run_ctx_mgr_#{System.unique_integer([:positive, :monotonic])}",
      job_id: job_id,
      run_id: "router_ctx_mgr",
      status: :completed,
      started_at_ms: LemonCore.Clock.now_ms(),
      completed_at_ms: LemonCore.Clock.now_ms(),
      duration_ms: 5,
      triggered_by: :schedule,
      output: output
    }

    :ok = CronStore.put_run(run)
    run
  end
end
