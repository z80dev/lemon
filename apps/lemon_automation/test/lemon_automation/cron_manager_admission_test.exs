defmodule LemonAutomation.CronManagerAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore, RunSubmitter, Wake}
  alias LemonCore.{Bus, Event, ProfileStore, SessionKey}

  @moduletag :tmp_dir
  @allowed_origin "https://cron-admission.example.test"

  defmodule Admission do
    @moduledoc false

    def check(job, run) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:admission_checked, job, run})
      :persistent_term.get({__MODULE__, :result}, :ok)
    end
  end

  defmodule ReadyPreflight do
    @moduledoc false

    def check(job) do
      send(:persistent_term.get({Admission, :test_pid}), {:preflight_checked, job.id})
      :ok
    end

    def current_default_model, do: {:ok, "test-default-model"}
  end

  defmodule Submitter do
    @moduledoc false

    def submit(job, run, opts) do
      send(:persistent_term.get({Admission, :test_pid}), {:submit_attempted, job.id, run.id})

      case :persistent_term.get({__MODULE__, :mode}, :tattle) do
        :tattle ->
          {:ok, "submitted"}

        :profile ->
          RunSubmitter.submit(
            job,
            run,
            Keyword.merge(opts,
              router_mod: LemonAutomation.CronManagerAdmissionTest.Router,
              waiter_mod: LemonAutomation.CronManagerAdmissionTest.Waiter,
              append_memory: false
            )
          )
      end
    end
  end

  defmodule Router do
    @moduledoc false

    def submit(params) do
      send(:persistent_term.get({Admission, :test_pid}), {:router_submitted, params})
      {:ok, params.run_id}
    end
  end

  defmodule Waiter do
    @moduledoc false

    def wait_already_subscribed(run_id, _timeout_ms, _opts) do
      send(:persistent_term.get({Admission, :test_pid}), {:waited_for, run_id})
      {:ok, "profile run completed"}
    end
  end

  setup %{tmp_dir: root} do
    token = System.unique_integer([:positive, :monotonic])
    prefix = "admission-test-#{token}-"
    profile_id = "cron-admission-#{token}"
    config = Path.join(root, "config.toml")
    File.write!(config, "")

    env_keys = [
      :cron_admission_mod,
      :cron_admission_allowed_origins,
      :cron_run_submitter,
      :cron_preflight_mod,
      :cron_drift_guard
    ]

    previous_env = Map.new(env_keys, &{&1, Application.fetch_env(:lemon_automation, &1)})
    previous_paths = Application.fetch_env(:lemon_core, :paths)
    paths = Application.get_env(:lemon_core, :paths) || []

    Application.put_env(
      :lemon_core,
      :paths,
      paths |> Keyword.put(:global_config, config) |> Keyword.put(:home_state_dir, root)
    )

    Application.put_env(:lemon_automation, :cron_admission_mod, Admission)
    Application.put_env(:lemon_automation, :cron_admission_allowed_origins, [@allowed_origin])
    Application.put_env(:lemon_automation, :cron_run_submitter, Submitter)
    Application.put_env(:lemon_automation, :cron_preflight_mod, ReadyPreflight)
    Application.put_env(:lemon_automation, :cron_drift_guard, enabled: false)
    :persistent_term.put({Admission, :test_pid}, self())
    :persistent_term.put({Admission, :result}, :ok)
    :persistent_term.put({Submitter, :mode}, :tattle)

    on_exit(fn ->
      for job <- CronManager.list(), String.starts_with?(job.name || "", prefix) do
        _ = CronManager.remove(job.id)
        for run <- CronStore.list_runs(job.id, limit: 200), do: CronStore.delete_run(run.id)

        for event <- CronStore.list_audit_events(job_id: job.id, limit: 200) do
          CronStore.delete_audit_event(event.id)
        end
      end

      for {key, value} <- previous_env, do: restore_env(:lemon_automation, key, value)
      restore_env(:lemon_core, :paths, previous_paths)
      :persistent_term.erase({Admission, :test_pid})
      :persistent_term.erase({Admission, :result})
      :persistent_term.erase({Submitter, :mode})
    end)

    assert {:ok, profile} =
             ProfileStore.create(%{
               id: profile_id,
               node: "worker-before-update",
               model: "profile-model-before-update",
               systemPrompt: "Initial cron persona"
             })

    admission = %{
      url: @allowed_origin <> "/callbacks/cron/#{token}",
      token_secret: "cron_admission_token_#{token}",
      routine_id: "routine-#{token}",
      creator_id: "creator-#{token}",
      workspace_id: "workspace-#{token}"
    }

    {:ok,
     prefix: prefix,
     profile_id: profile_id,
     profile: profile,
     agent_id: "cron_owner_#{token}",
     session_key: "agent:cron_owner_#{token}:main",
     admission: admission,
     root: root}
  end

  for outcome <- [:denied, :admission_unavailable], trigger <- [:manual, :schedule, :wake, :retry] do
    test "#{outcome} terminalizes #{trigger} before preflight or submission and never retries", ctx do
      outcome = unquote(outcome)
      trigger = unquote(trigger)
      :persistent_term.put({Admission, :result}, {:error, outcome})
      assert {:ok, job} = add_job(ctx, max_retries: 3, retry_backoff_ms: 0)
      {run_id, source_id} = dispatch(job, trigger)
      job_id = job.id

      assert_receive {:admission_checked, checked_job, checked_run}, 5_000
      assert checked_job.id == job_id
      assert checked_job.profile_id == ctx.profile_id
      assert checked_job.admission == ctx.admission
      assert checked_run.id == run_id
      assert checked_run.triggered_by == trigger
      assert is_binary(checked_run.run_id) and checked_run.run_id != ""

      run = await_terminal(run_id)
      assert run.status == :failed
      assert run.error == Atom.to_string(outcome)
      assert meta(run, :admission_outcome) == outcome
      assert run.run_id == checked_run.run_id
      assert is_integer(run.completed_at_ms)
      assert meta(run, :retry_due_at_ms) == nil
      assert meta(run, :retry_next_attempt) == nil

      # Drain a further tick after terminalization: failure must not leave durable
      # retry intent or launch another admission check, even with zero backoff.
      CronManager.tick()
      _ = :sys.get_state(CronManager)
      refute_receive {:preflight_checked, ^job_id}, 100
      refute_receive {:submit_attempted, ^job_id, _}, 100
      refute_receive {:router_submitted, _}, 100
      refute_receive {:admission_checked, %{id: ^job_id}, _}, 100

      expected_ids = if source_id, do: [source_id, run_id], else: [run_id]
      assert Enum.sort(Enum.map(CronStore.list_runs(job.id, limit: 20), & &1.id)) ==
               Enum.sort(expected_ids)

      refute Enum.any?(CronStore.pending_retries(), &(&1.job_id == job.id))
      refute Enum.any?(audit_events(job.id), &(&1.action == "retry_scheduled"))
    end
  end

  test "approval submits through the real profile resolver to its current destination node", ctx do
    :persistent_term.put({Submitter, :mode}, :profile)
    assert {:ok, job} = add_job(ctx)

    assert {:ok, _} =
             ProfileStore.update(ctx.profile_id, %{
               node: "worker-canonical-destination",
               model: "profile-model-current",
               systemPrompt: "Current cron persona"
             })

    File.write!(Path.join(ctx.profile["paths"]["workspace"], "SOUL.md"), "Current instructions")
    assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
    job_id = job.id

    assert_receive {:admission_checked, checked_job, checked_run}, 5_000
    assert checked_job.id == job_id
    assert checked_run.id == run_id
    assert_receive {:preflight_checked, ^job_id}, 5_000
    assert_receive {:submit_attempted, ^job_id, ^run_id}, 5_000
    assert_receive {:router_submitted, params}, 5_000
    assert params.run_id == checked_run.run_id
    assert params.origin == :cron
    assert params.agent_id == ctx.profile_id
    assert params.agent_id != job.agent_id
    assert params.model == "profile-model-current"
    assert params.meta.node == "worker-canonical-destination"
    assert params.meta.profile_id == ctx.profile_id
    assert params.meta.system_prompt == "Current cron persona"
    assert params.meta.profile_instructions["SOUL.md"] == "Current instructions"
    assert params.meta.cron_job_id == job.id
    assert params.meta.cron_run_id == run_id
    assert params.meta.cron_base_session_key == job.session_key
    assert params.meta.cron_session_key == params.session_key
    assert params.meta.remote_cwd_explicit == false
    assert params.cwd == nil
    assert params.tool_policy.blocked_tools == ["cron"]
    assert SessionKey.valid?(params.session_key)
    assert params.session_key != job.session_key
    assert_private_free(params, ctx.admission)
    assert_receive {:waited_for, router_id}, 5_000
    assert router_id == params.run_id

    run = await_terminal(run_id)
    assert run.status == :completed
    assert run.output == "profile run completed"
    assert run.error == nil
  end

  test "the production admission default lets a job with no hook reach the submitter", ctx do
    Application.delete_env(:lemon_automation, :cron_admission_mod)
    assert {:ok, job} = add_job(ctx, admission: nil, enabled: false)
    assert job.admission == nil
    assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
    job_id = job.id

    assert_receive {:preflight_checked, ^job_id}, 5_000
    assert_receive {:submit_attempted, ^job_id, ^run_id}, 5_000
    refute_receive {:admission_checked, _, _}, 100
    assert await_terminal(run_id).status == :completed
  end

  test "unrelated updates retain private admission and explicit nil clears it", ctx do
    string_admission = Map.new(ctx.admission, fn {key, value} -> {Atom.to_string(key), value} end)
    assert {:ok, job} = add_job(ctx, admission: string_admission)
    assert job.admission == ctx.admission
    assert CronStore.get_job(job.id).admission == ctx.admission

    assert {:ok, updated} = CronManager.update(job.id, %{prompt: "updated work"})
    assert updated.admission == ctx.admission
    assert CronStore.get_job(job.id).admission == ctx.admission
    assert_private_free(CronJob.to_map(updated), ctx.admission)

    assert {:ok, cleared} = CronManager.update(job.id, %{admission: nil})
    assert cleared.admission == nil
    assert CronStore.get_job(job.id).admission == nil
    assert_private_free(CronJob.to_map(cleared), ctx.admission)
  end

  test "public cron projections, emitted events, durable runs and audits omit private admission", ctx do
    Bus.subscribe("cron")
    on_exit(fn -> Bus.unsubscribe("cron") end)
    :persistent_term.put({Admission, :result}, {:error, :admission_unavailable})
    assert {:ok, job} = add_job(ctx)
    job_id = job.id

    assert_receive %Event{type: :cron_job_created, payload: %{job_id: ^job_id}} = created, 5_000
    assert_private_free(created, ctx.admission)
    assert_private_free(CronJob.to_map(job), ctx.admission)
    assert CronStore.get_job(job.id).admission == ctx.admission

    assert {:ok, updated} = CronManager.update(job.id, %{prompt: "different work"})
    assert_receive %Event{type: :cron_job_updated, payload: %{job_id: ^job_id}} = changed, 5_000
    assert_private_free(changed, ctx.admission)
    assert_private_free(CronJob.to_map(updated), ctx.admission)

    assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
    assert_receive %Event{type: :cron_run_started, payload: %{cron_run_id: ^run_id}} = started,
                   5_000

    assert_receive %Event{type: :cron_run_completed, payload: %{cron_run_id: ^run_id}} = completed,
                   5_000

    assert_private_free(started, ctx.admission)
    assert_private_free(completed, ctx.admission)
    run = await_terminal(run_id)
    assert run.error == "admission_unavailable"
    assert_private_free(run, ctx.admission)
    assert_private_free(CronRun.to_map(run), ctx.admission)

    audits = audit_events(job.id)
    assert audits != []
    for audit <- audits, do: assert_private_free(audit, ctx.admission)

    for audit <- audits do
      audit_id = audit.id
      assert_receive %Event{type: :cron_lifecycle_action, payload: %{audit: %{id: ^audit_id}}} = event,
                     5_000

      assert_private_free(event, ctx.admission)
    end
  end

  test "raw callback tokens are rejected rather than accepted into job configuration", ctx do
    raw_token = "raw-cron-admission-token-must-not-be-stored"
    admission = Map.put(ctx.admission, :token, raw_token)
    assert {:error, _reason} = add_job(ctx, admission: admission)
    refute Enum.any?(CronManager.list(), &String.starts_with?(&1.name || "", ctx.prefix))
  end

  defp add_job(ctx, extra \\ []) do
    CronManager.add(
      Map.merge(
        %{
          name: ctx.prefix <> Integer.to_string(System.unique_integer([:positive])),
          # Tests drive due slots explicitly rather than racing the minute tick.
          schedule: "0 0 1 1 *",
          timezone: "UTC",
          agent_id: ctx.agent_id,
          session_key: ctx.session_key,
          profile_id: ctx.profile_id,
          prompt: "do admission-controlled work",
          admission: ctx.admission,
          memory_file: Path.join(ctx.root, "cron-memory.md"),
          deliver_to: "none"
        },
        Map.new(extra)
      )
    )
  end

  defp dispatch(job, :manual) do
    assert {:ok, %CronRun{id: run_id, triggered_by: :manual}} = CronManager.run_now(job.id)
    {run_id, nil}
  end

  defp dispatch(job, :wake) do
    assert {:ok, %CronRun{id: run_id, triggered_by: :wake}} = Wake.trigger(job.id)
    {run_id, nil}
  end

  defp dispatch(job, :schedule) do
    scheduled_for_ms = LemonCore.Clock.now_ms() - 1_000
    replace_job_state(%{job | next_run_at_ms: scheduled_for_ms})
    CronManager.tick()
    {CronStore.scheduled_run_id(job.id, scheduled_for_ms), nil}
  end

  defp dispatch(job, :retry) do
    # Seed an ordinary failed source with the existing durable retry contract.
    # The callback failure being tested belongs to the retry, not its source.
    now = LemonCore.Clock.now_ms()
    source = job.id |> CronRun.new(:schedule) |> CronRun.start() |> CronRun.fail("ordinary failure")

    source = %{
      source
      | meta: %{
          retry_attempt: 0,
          retry_root_id: source.id,
          retry_next_attempt: 1,
          retry_due_at_ms: now - 1_000
        }
    }

    CronStore.put_run(source)
    replace_job_state(%{job | next_run_at_ms: now + 86_400_000})
    CronManager.tick()
    {CronStore.retry_run_id(source.id, 1), source.id}
  end

  defp replace_job_state(job) do
    CronStore.put_job(job)
    :sys.replace_state(CronManager, fn state -> put_in(state.jobs[job.id], job) end)
  end

  defp audit_events(job_id), do: CronStore.list_audit_events(job_id: job_id, limit: 200)

  defp meta(run, key), do: Map.get(run.meta || %{}, key) || Map.get(run.meta || %{}, Atom.to_string(key))

  defp assert_private_free(value, admission) do
    rendered = inspect(value, limit: :infinity, printable_limit: :infinity)
    for private_value <- Map.values(admission), do: refute(rendered =~ private_value)
    refute_private_keys(value)
  end

  defp refute_private_keys(value) when is_map(value) do
    for {key, nested} <- Map.to_list(value) do
      refute key in [
               :admission,
               "admission",
               :token,
               "token",
               :token_secret,
               "token_secret",
               :routine_id,
               "routine_id",
               :creator_id,
               "creator_id",
               :workspace_id,
               "workspace_id"
             ]

      refute_private_keys(nested)
    end
  end

  defp refute_private_keys(value) when is_list(value), do: Enum.each(value, &refute_private_keys/1)
  defp refute_private_keys(_value), do: :ok

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)

  defp await_terminal(run_id, attempts \\ 500)

  defp await_terminal(run_id, 0), do: flunk("cron run #{run_id} did not terminalize")

  defp await_terminal(run_id, attempts) do
    case CronStore.get_run(run_id) do
      %CronRun{status: status} = run when status in [:completed, :failed, :timeout, :aborted] ->
        run

      _ ->
        Process.sleep(10)
        await_terminal(run_id, attempts - 1)
    end
  end
end
