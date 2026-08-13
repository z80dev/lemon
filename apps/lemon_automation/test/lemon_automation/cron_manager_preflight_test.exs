defmodule LemonAutomation.CronManagerPreflightTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}
  alias LemonCore.{Bus, Event}

  defmodule TattleSubmitter do
    @moduledoc false

    def submit(job, run, _opts) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:cron_submit, job.id, run.id, run.triggered_by})
      {:ok, "submitted"}
    end
  end

  defmodule SkippingPreflight do
    @moduledoc false

    def check(_job) do
      {:skip, %{class: :no_ready_provider, detail: "0 of 3 providers credential-ready"}}
    end

    def current_default_model, do: {:ok, "model-a"}
  end

  setup do
    previous_submitter = Application.get_env(:lemon_automation, :cron_run_submitter)
    previous_preflight_mod = Application.get_env(:lemon_automation, :cron_preflight_mod)
    previous_preflight = Application.get_env(:lemon_automation, :cron_preflight)
    previous_drift = Application.get_env(:lemon_automation, :cron_drift_guard)
    previous_model_fun = Application.get_env(:lemon_automation, :cron_default_model_fun)
    previous_drift_env = System.get_env("LEMON_CRON_DRIFT_GUARD_ENABLED")

    Application.put_env(:lemon_automation, :cron_run_submitter, TattleSubmitter)
    :persistent_term.put({TattleSubmitter, :test_pid}, self())

    token = System.unique_integer([:positive, :monotonic])
    agent_id = "cron_pf_mgr_#{token}"
    base_session_key = "agent:#{agent_id}:main"

    on_exit(fn ->
      restore_app_env(:cron_run_submitter, previous_submitter)
      restore_app_env(:cron_preflight_mod, previous_preflight_mod)
      restore_app_env(:cron_preflight, previous_preflight)
      restore_app_env(:cron_drift_guard, previous_drift)
      restore_app_env(:cron_default_model_fun, previous_model_fun)
      restore_system_env("LEMON_CRON_DRIFT_GUARD_ENABLED", previous_drift_env)

      :persistent_term.erase({TattleSubmitter, :test_pid})

      for job <- CronManager.list(), String.contains?(job.name || "", "-#{token}") do
        for run <- CronStore.list_runs(job.id, limit: 200), do: CronStore.delete_run(run.id)
        for event <- audit_events(job.id), do: CronStore.delete_audit_event(event.id)
        _ = CronManager.remove(job.id)
      end
    end)

    {:ok, token: token, agent_id: agent_id, base_session_key: base_session_key}
  end

  describe "preflight skip" do
    setup ctx do
      Application.put_env(:lemon_automation, :cron_preflight_mod, SkippingPreflight)

      topic = Bus.session_topic(ctx.base_session_key)
      Bus.subscribe(topic)
      on_exit(fn -> Bus.unsubscribe(topic) end)

      :ok
    end

    test "a skipped dispatch never reaches the submitter and persists a failed run", ctx do
      {:ok, job} = add_job(ctx, max_retries: 0)

      assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)

      refute_receive {:cron_submit, _job_id, ^run_id, _trigger}, 300

      assert await(fn -> match?(%CronRun{status: :failed}, CronStore.get_run(run_id)) end)

      run = CronStore.get_run(run_id)
      assert String.starts_with?(run.error, "preflight:no_ready_provider:")
      assert run.error =~ "0 of 3 providers credential-ready"

      failure = run.meta[:preflight_failure] || run.meta["preflight_failure"]
      assert failure != nil

      assert "preflight_failed" in audit_actions(job.id)

      assert_receive %Event{
                       type: :run_completed,
                       payload: %{completed: %{ok: false, answer: answer}}
                     },
                     5_000

      assert answer =~ "preflight:no_ready_provider"
    end

    test "consecutive identical preflight skips are forwarded once", ctx do
      {:ok, job} = add_job(ctx, max_retries: 0)

      base = LemonCore.Clock.now_ms() - 600_000

      run_ids =
        for slot <- 0..2 do
          run_id = force_due(job, base + slot * 60_000)
          assert await(fn -> match?(%CronRun{status: :failed}, CronStore.get_run(run_id)) end)
          run_id
        end

      # All three runs are persisted and audited...
      assert length(Enum.uniq(run_ids)) == 3
      assert Enum.count(audit_actions(job.id), &(&1 == "preflight_failed")) == 3

      # ...but only the first is forwarded to the originating session; the
      # repeats are suppressed instead of spamming it once per tick.
      assert_receive %Event{type: :run_completed, payload: %{completed: %{ok: false}}}, 5_000
      refute_receive %Event{type: :run_completed}, 500

      statuses = Enum.map(run_ids, &CronStore.get_run(&1).suppressed)
      assert statuses == [false, true, true]
      assert "preflight_notice_suppressed" in audit_actions(job.id)
    end

    test "a preflight skip is not retried", ctx do
      {:ok, job} = add_job(ctx, max_retries: 2, retry_backoff_ms: 0)

      scheduled_for_ms = LemonCore.Clock.now_ms() - 120_000
      run_id = force_due(job, scheduled_for_ms)

      assert await(fn -> match?(%CronRun{status: :failed}, CronStore.get_run(run_id)) end)

      refute_receive {:cron_submit, _job_id, _run_id, _trigger}, 500

      runs = CronStore.list_runs(job.id, limit: 20)
      assert Enum.map(runs, & &1.id) == [run_id]
      refute "retry_scheduled" in audit_actions(job.id)
    end
  end

  describe "model drift end to end" do
    setup do
      System.put_env("LEMON_CRON_DRIFT_GUARD_ENABLED", "true")
      Application.put_env(:lemon_automation, :cron_default_model_fun, fn -> current_model() end)
      set_model("model-a")
      :ok
    end

    test "drift blocks dispatch until the model is re-captured", ctx do
      {:ok, job} = add_job(ctx, [])
      assert job.captured_default_model == "model-a"

      set_model("model-b")

      assert {:ok, %CronRun{id: blocked_run_id}} = CronManager.run_now(job.id)
      refute_receive {:cron_submit, _job_id, ^blocked_run_id, _trigger}, 300

      assert await(fn -> match?(%CronRun{status: :failed}, CronStore.get_run(blocked_run_id)) end)
      assert CronStore.get_run(blocked_run_id).error =~ "preflight:model_drift"
      assert "preflight_failed" in audit_actions(job.id)

      assert {:ok, %CronJob{captured_default_model: "model-b"}} =
               CronManager.refresh_captured_model(job.id)

      assert "model_recaptured" in audit_actions(job.id)

      assert {:ok, %CronRun{id: allowed_run_id}} = CronManager.run_now(job.id)
      assert_receive {:cron_submit, _job_id, ^allowed_run_id, :manual}, 5_000
    end

    test "pinning a model also unblocks dispatch", ctx do
      {:ok, job} = add_job(ctx, [])
      assert job.captured_default_model == "model-a"

      set_model("model-b")

      assert {:ok, %CronJob{model: "model-b"}} =
               CronManager.update(job.id, %{model: "model-b"})

      assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
      assert_receive {:cron_submit, _job_id, ^run_id, :manual}, 5_000
    end

    test "captured_default_model cannot be patched through update/2", ctx do
      {:ok, job} = add_job(ctx, [])

      assert {:error, {:immutable_fields, [:captured_default_model]}} =
               CronManager.update(job.id, %{captured_default_model: "model-x"})

      assert CronStore.get_job(job.id).captured_default_model == "model-a"
    end

    test "an explicitly pinned job captures no default at creation", ctx do
      {:ok, job} = add_job(ctx, model: "model-pinned")

      assert job.model == "model-pinned"
      assert job.captured_default_model == nil
    end

    test "clearing a model pin re-captures the drift baseline", ctx do
      {:ok, job} = add_job(ctx, model: "model-pinned")
      assert job.captured_default_model == nil

      # Unpinning returns the job to the global default, so it needs a baseline
      # from that moment on — otherwise the drift guard is dead for this job.
      assert {:ok, %CronJob{model: nil, captured_default_model: "model-a"}} =
               CronManager.update(job.id, %{model: nil})

      assert CronStore.get_job(job.id).captured_default_model == "model-a"

      set_model("model-b")

      assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
      refute_receive {:cron_submit, _job_id, ^run_id, _trigger}, 300

      assert await(fn -> match?(%CronRun{status: :failed}, CronStore.get_run(run_id)) end)
      assert CronStore.get_run(run_id).error =~ "preflight:model_drift"
    end

    test "an unrelated update leaves an existing baseline alone", ctx do
      {:ok, job} = add_job(ctx, [])
      assert job.captured_default_model == "model-a"

      set_model("model-b")

      assert {:ok, %CronJob{captured_default_model: "model-a"}} =
               CronManager.update(job.id, %{prompt: "do other work"})
    end
  end

  defp add_job(ctx, extra) do
    CronManager.add(
      Map.merge(
        %{
          name: "preflight-test-#{ctx.token}-#{System.unique_integer([:positive])}",
          schedule: "* * * * *",
          agent_id: ctx.agent_id,
          session_key: ctx.base_session_key,
          prompt: "do work",
          timezone: "UTC"
        },
        Map.new(extra)
      )
    )
  end

  defp force_due(%CronJob{} = job, scheduled_for_ms) do
    stored = CronStore.get_job(job.id) || job
    due = %{stored | next_run_at_ms: scheduled_for_ms, enabled: true}

    CronStore.put_job(due)
    :sys.replace_state(CronManager, fn state -> put_in(state.jobs[job.id], due) end)

    CronManager.tick()
    CronStore.scheduled_run_id(job.id, scheduled_for_ms)
  end

  defp set_model(model), do: :persistent_term.put({__MODULE__, :model}, model)

  defp current_model, do: {:ok, :persistent_term.get({__MODULE__, :model}, nil)}

  defp audit_events(job_id), do: CronStore.list_audit_events(job_id: job_id, limit: 200)

  defp audit_actions(job_id), do: Enum.map(audit_events(job_id), & &1.action)

  defp restore_app_env(key, nil), do: Application.delete_env(:lemon_automation, key)
  defp restore_app_env(key, value), do: Application.put_env(:lemon_automation, key, value)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)

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
