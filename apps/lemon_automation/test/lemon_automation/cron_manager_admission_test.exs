defmodule LemonAutomation.CronManagerAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore, RunSubmitter, Wake}
  alias LemonCore.{Bus, Event, ProfileStore, SessionKey, ToolPolicy}

  @moduletag :tmp_dir
  @allowed_origin "https://cron-admission.example.test"

  defmodule Admission do
    @moduledoc false

    def check(job, run) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:admission_checked, job, run})
      case :persistent_term.get({__MODULE__, :result}, :ok) do
        callback when is_function(callback, 2) -> callback.(job, run)
        result -> result
      end
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
    previous_allowed_origins = System.get_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS")
    System.delete_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS")
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

      if is_nil(previous_allowed_origins) do
        System.delete_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS")
      else
        System.put_env("LEMON_CRON_ADMISSION_ALLOWED_ORIGINS", previous_allowed_origins)
      end
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
      {run_id, expected_ids} = dispatch(job, trigger)
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
               systemPrompt: "Current cron persona",
               mcpServers: owner_mcp_servers()
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
    assert params.cwd == nil
    assert SessionKey.valid?(params.session_key)
    assert params.session_key != job.session_key
    assert_private_free(params, ctx.admission)
    assert params.meta.mcp_servers == owner_mcp_servers()
    refute Map.has_key?(params.meta, :invocation_context_key)
    assert "cron" in params.tool_policy.blocked_tools
    assert_receive {:waited_for, router_id}, 5_000
    assert router_id == params.run_id

    run = await_terminal(run_id)
    assert run.status == :completed
    assert run.output == "profile run completed"
    assert run.error == nil
  end

  for connectors <- [:caller, :core_only] do
    test "approved #{connectors} invocation replaces owner MCP and retains every policy floor", ctx do
      connectors = unquote(connectors)
      Bus.subscribe("cron")
      on_exit(fn -> Bus.unsubscribe("cron") end)
      :persistent_term.put({Admission, :result}, fn _job, run ->
        {:ok, invocation_projection(ctx, connectors, run.run_id)}
      end)
      :persistent_term.put({Submitter, :mode}, :profile)
      assert {:ok, job} = add_job(ctx, model: "cron-team-model-pin")
      job_id = job.id

      assert {:ok, _} =
               ProfileStore.update(ctx.profile_id, %{
                 node: "worker-team-current",
                 model: "profile-model-current",
                 mcpServers: owner_mcp_servers(),
                 toolPolicy: %{
                   "allow" => ["read", "bash", "cron"],
                   "deny" => ["write"],
                   "blocked_tools" => ["edit"],
                   "require_approval" => ["bash"],
                   "approvals" => %{"bash" => "always"}
                 }
               })

      assert_receive %Event{type: :cron_job_created, payload: %{job_id: ^job_id}} = created,
                     5_000

      assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
      assert_receive {:admission_checked, checked_job, checked_run}, 5_000
      assert checked_job.id == job.id
      assert checked_run.id == run_id
      projection = invocation_projection(ctx, connectors, checked_run.run_id)
      assert_receive {:preflight_checked, ^job_id}, 5_000
      assert_receive {:submit_attempted, ^job_id, ^run_id}, 5_000
      assert_receive {:router_submitted, params}, 5_000
      assert params.run_id == checked_run.run_id
      assert params.origin == :cron
      assert params.agent_id == ctx.profile_id
      assert params.meta.node == "worker-team-current"
      assert params.meta.profile_id == ctx.profile_id
      assert_execution_context(params, projection, checked_run.run_id)
      refute inspect(params, limit: :infinity) =~ "CRON_OWNER_MCP_KEY"
      assert params.model == "cron-team-model-pin"
      assert params.meta.cron_model_pin == "cron-team-model-pin"
      assert params.meta.cron_base_session_key == job.session_key
      assert params.meta.cron_session_key == params.session_key
      assert params.meta.cron_job_id == job.id
      assert params.meta.cron_run_id == run_id
      assert SessionKey.valid?(params.session_key)
      assert params.session_key != job.session_key
      assert params.cwd == nil
      assert params.tool_policy.allow == ["read", "bash", "cron"]
      assert "write" in params.tool_policy.deny
      assert "edit" in params.tool_policy.blocked_tools
      assert "cron" in params.tool_policy.blocked_tools
      assert "bash" in params.tool_policy.require_approval
      assert params.tool_policy.approvals["bash"] in [:always, "always"]
      assert_private_free(params, ctx.admission)
      refute Map.has_key?(params, :admission_invocation)
      refute Map.has_key?(params.meta, :admission_invocation)
      assert_receive {:waited_for, router_id}, 5_000
      assert router_id == params.run_id

      run = await_terminal(run_id)
      assert run.status == :completed
      assert run.run_id == params.run_id
      assert run.output == "profile run completed"
      assert run.error == nil

      # A second launch must receive its own proof, not the previous run's receipt.
      assert {:ok, %CronRun{id: second_run_id}} = CronManager.run_now(job.id)
      assert_receive {:admission_checked, _, second_checked_run}, 5_000
      assert_receive {:router_submitted, second_params}, 5_000
      assert second_params.run_id == second_checked_run.run_id
      refute second_params.run_id == params.run_id
      second_projection = invocation_projection(ctx, connectors, second_params.run_id)
      assert_execution_context(second_params, second_projection, second_params.run_id)
      refute second_params.meta.invocation_proof == params.meta.invocation_proof
      assert await_terminal(second_run_id).status == :completed
      assert_receive %Event{type: :cron_run_started, payload: %{cron_run_id: ^run_id}} = started,
                     5_000

      assert_receive %Event{type: :cron_run_completed, payload: %{cron_run_id: ^run_id}} = completed,
                     5_000

      for value <- [
            CronJob.to_map(CronStore.get_job(job.id)),
            run,
            CronRun.to_map(run),
            created,
            started,
            completed
          ] do
        assert_private_free(value, ctx.admission)
        assert_invocation_private_free(value, projection)
      end

      assert_invocation_private_free(CronStore.get_job(job.id), projection)
      audits = audit_events(job.id)
      assert audits != []

      for audit <- audits do
        assert_private_free(audit, ctx.admission)
        assert_invocation_private_free(audit, projection)
        audit_id = audit.id
        assert_receive %Event{type: :cron_lifecycle_action, payload: %{audit: %{id: ^audit_id}}} = event,
                       5_000

        assert_private_free(event, ctx.admission)
        assert_invocation_private_free(event, projection)
      end
    end
  end

  test "malformed private invocation opts fail before router submission or ownership claim", ctx do
    assert {:ok, job} = add_job(ctx, enabled: false)
    run = CronRun.new(job.id, :manual)
    router_id = LemonCore.Id.run_id()
    projection = invocation_projection(ctx, :caller, router_id)
    [server | _] = projection.mcp_servers
    borrowed = invocation_projection(ctx, :caller, LemonCore.Id.run_id())

    malformed = [
      nil,
      %{},
      Map.delete(projection, :tool_policy),
      Map.put(projection, :extra, true),
      Map.new(projection, fn {key, value} -> {Atom.to_string(key), value} end),
      %{projection | context_key: nil},
      %{projection | context_key: "unsafe/context"},
      %{projection | context_key: String.duplicate("a", 129)},
      %{projection | memory_key: nil},
      %{projection | memory_key: "unsafe/memory"},
      %{projection | memory_key: String.duplicate("a", 129)},
      %{projection | shared_memory_grant: true},
      %{projection | proof: nil},
      %{projection | proof: borrowed.proof},
      %{projection | mcp_servers: borrowed.mcp_servers},
      %{projection | mcp_servers: []},
      Map.take(projection, [:context_key, :mcp_servers, :tool_policy]),
      %{projection | mcp_servers: nil},
      %{projection | mcp_servers: [Map.put(server, "unknown", "value")]},
      %{projection | mcp_servers: [Map.put(server, "headers", %{"Authorization" => "raw-token"})]},
      %{projection | tool_policy: nil},
      %{projection | tool_policy: %{"unknown" => true}},
      %{projection | tool_policy: %{allow: :all}},
      %{
        "invocationContextKey" => projection.context_key,
        "invocationMcpServers" => projection.mcp_servers,
        "invocationToolPolicy" => projection.tool_policy
      }
    ]

    for invocation <- malformed do
      assert {:error, :admission_unavailable} =
               RunSubmitter.submit(job, run, submission_opts(invocation, router_id))

      assert {:error, :admission_unavailable} =
               RunSubmitter.build_params(job, run, router_id, submission_opts(invocation, router_id))
    end

    refute_receive {:submission_claimed, _, _}, 100
    refute_receive {:router_submitted, _}, 100
    refute_receive {:waited_for, _}, 100
  end

  test "private invocation opts cannot grant unconfigured, nonprofile or command jobs", ctx do
    assert {:ok, job} = add_job(ctx, enabled: false)
    run = CronRun.new(job.id, :manual)
    router_id = LemonCore.Id.run_id()
    projection = invocation_projection(ctx, :caller, router_id)

    for invalid_job <- [
          %{job | admission: nil},
          %{job | profile_id: nil},
          %{job | command: "echo operator-owned"}
        ] do
      assert {:error, :admission_unavailable} =
               RunSubmitter.submit(invalid_job, run, submission_opts(projection, router_id))
    end

    refute_receive {:submission_claimed, _, _}, 100
    refute_receive {:router_submitted, _}, 100
    refute_receive {:waited_for, _}, 100
  end

  test "whitespace command retains agent execution with a canonical private invocation", ctx do
    assert {:ok, job} = add_job(ctx, enabled: false, command: " \n\t")
    run = CronRun.new(job.id, :manual)
    router_id = LemonCore.Id.run_id()
    projection = invocation_projection(ctx, :caller, router_id)

    assert {:ok, "profile run completed"} =
             RunSubmitter.submit(job, run, submission_opts(projection, router_id))

    assert_receive {:submission_claimed, ^router_id, session_key}, 5_000
    assert_receive {:router_submitted, params}, 5_000
    assert params.run_id == router_id
    assert params.session_key == session_key
    assert params.session_key != job.session_key
    assert_execution_context(params, projection, router_id)
    assert "cron" in params.tool_policy.blocked_tools
    assert_receive {:waited_for, ^router_id}, 5_000
  end

  test "job without admission keeps normal execution", ctx do
    :persistent_term.put({Submitter, :mode}, :profile)
    assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{mcpServers: owner_mcp_servers()})
    assert {:ok, job} = add_job(ctx, admission: nil, enabled: false)
    assert job.admission == nil
    assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
    job_id = job.id

    assert_receive {:preflight_checked, ^job_id}, 5_000
    assert_receive {:submit_attempted, ^job_id, ^run_id}, 5_000
    assert_receive {:router_submitted, params}, 5_000
    assert params.meta.mcp_servers == owner_mcp_servers()
    refute Map.has_key?(params.meta, :invocation_context_key)
    assert "cron" in params.tool_policy.blocked_tools
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

  for invalid <- [:stale, :borrowed_header, :memory_nil, :shared_grant, :none, :legacy_projection] do
    test "approved #{invalid} projection fails unavailable without router launch or owner fallback", ctx do
      invalid = unquote(invalid)
      :persistent_term.put({Submitter, :mode}, :profile)
      assert {:ok, _} = ProfileStore.update(ctx.profile_id, %{mcpServers: owner_mcp_servers()})
      assert {:ok, job} = add_job(ctx, enabled: false, max_retries: 3)

      :persistent_term.put({Admission, :result}, fn _job, run ->
        projection = invocation_projection(ctx, :caller, run.run_id)
        borrowed = invocation_projection(ctx, :caller, LemonCore.Id.run_id())

        projection =
          case invalid do
            :stale -> borrowed
            :borrowed_header -> %{projection | mcp_servers: borrowed.mcp_servers}
            :memory_nil -> %{projection | memory_key: nil}
            :shared_grant -> %{projection | shared_memory_grant: true}
            :none -> invocation_projection(ctx, :none, run.run_id)
            :legacy_projection -> Map.take(projection, [:context_key, :mcp_servers, :tool_policy])
          end

        {:ok, projection}
      end)

      assert {:ok, %CronRun{id: run_id}} = CronManager.run_now(job.id)
      job_id = job.id
      assert_receive {:admission_checked, _, checked_run}, 5_000
      assert checked_run.id == run_id
      assert_receive {:submit_attempted, ^job_id, ^run_id}, 5_000
      run = await_terminal(run_id)
      assert run.status == :failed
      assert run.error == "admission_unavailable"
      assert meta(run, :admission_outcome) == :admission_unavailable
      assert meta(run, :retry_due_at_ms) == nil
      refute_receive {:router_submitted, _}, 100
      refute_receive {:waited_for, _}, 100
    end
  end

  test "projected build requires an actual nonempty fixed run ID", ctx do
    assert {:ok, job} = add_job(ctx, enabled: false)
    run = CronRun.new(job.id, :manual)
    projection = invocation_projection(ctx, :caller, LemonCore.Id.run_id())

    for run_id <- [nil, "", "unsafe/run", String.duplicate("a", 129)] do
      assert {:error, :admission_unavailable} =
               RunSubmitter.build_params(job, run, run_id, submission_opts(projection, run_id))
    end

    refute_receive {:submission_claimed, _, _}, 100
    refute_receive {:router_submitted, _}, 100
  end

  defp owner_mcp_servers do
    [
      %{
        "name" => "shared-connector",
        "url" => "https://mcp.example.test/tools",
        "headers" => %{"Authorization" => "Bearer ${LEMON_SECRET:CRON_OWNER_MCP_KEY}"}
      }
    ]
  end

  defp invocation_projection(ctx, connectors, run_id) do
    servers =
      case connectors do
        :caller ->
          [
            %{
              "name" => "shared-connector",
              "url" => "https://mcp.example.test/tools",
              "headers" => %{
                "Authorization" => "Bearer ${LEMON_SECRET:CRON_TEAM_CALLER_MCP_KEY}",
                "X-Team-Key" => "${LEMON_SECRET:CRON_TEAM_CONTEXT_KEY}"
              },
              "enabledTools" => ["lookup"],
              "allowedOrigins" => ["https://mcp.example.test"]
            }
          ]

        :none ->
          []

        :core_only ->
          []
      end

    proof = %{
      "runId" => run_id,
      "serverName" => "lemon-core-proof",
      "serverUrl" => "https://core.example.test/mcp",
      "headerName" => "X-Lemon-Bot-Invocation",
      "secretName" => "lemon_bot/invocations/" <> run_id
    }

    servers =
      if connectors == :none do
        []
      else
        [
          %{
            "name" => proof["serverName"],
            "url" => proof["serverUrl"],
            "headers" => %{
              proof["headerName"] => "${LEMON_SECRET:#{proof["secretName"]}}"
            }
          }
          | servers
        ]
      end

    assert {:ok, servers} = ProfileStore.normalize_mcp_servers(servers)
    assert {:ok, policy} =
             ToolPolicy.normalize(%{
               "profile" => "full_access",
               "allow" => "all",
               "approvals" => %{"bash" => "never"}
             })

    %{
      context_key: "team-caller:#{ctx.profile_id}:epoch-7",
      memory_key: "team-memory:#{ctx.profile_id}:epoch-7",
      mcp_servers: servers,
      tool_policy: policy,
      proof: proof,
      shared_memory_grant: false
    }
  end

  defp assert_execution_context(params, projection, run_id) do
    assert params.meta.invocation_context_key == projection.context_key
    assert params.meta.memory_context_key == projection.memory_key
    assert params.meta.memory_context_verified == true
    assert params.meta.shared_memory_grant == false
    assert params.meta.invocation_proof_verified == true
    assert params.meta.mcp_servers == projection.mcp_servers
    assert params.meta.invocation_proof == %{
      run_id: run_id,
      server_name: projection.proof["serverName"],
      server_url: projection.proof["serverUrl"],
      header_name: "X-Lemon-Bot-Invocation",
      secret_name: "lemon_bot/invocations/" <> run_id
    }

    core = Enum.find(params.meta.mcp_servers, &(&1["name"] == projection.proof["serverName"]))
    assert core["headers"]["X-Lemon-Bot-Invocation"] ==
             "${LEMON_SECRET:lemon_bot/invocations/#{run_id}}"
    refute inspect(params, limit: :infinity) =~ "CRON_OWNER_MCP_KEY"
  end

  defp submission_opts(invocation, run_id) do
    test_pid = self()

    [
      run_id: run_id,
      admission_invocation: invocation,
      router_mod: Router,
      waiter_mod: Waiter,
      append_memory: false,
      on_submitting: fn run_id, session_key ->
        send(test_pid, {:submission_claimed, run_id, session_key})
        :ok
      end
    ]
  end

  defp assert_invocation_private_free(value, projection) do
    rendered = inspect(value, limit: :infinity, printable_limit: :infinity)
    refute rendered =~ projection.context_key
    refute rendered =~ projection.memory_key
    refute rendered =~ "lemon_bot/invocations/"
    refute rendered =~ "CRON_TEAM_CALLER_MCP_KEY"
    refute rendered =~ "CRON_TEAM_CONTEXT_KEY"
    refute rendered =~ "admission_invocation"
    refute rendered =~ "invocation_context_key"
    refute rendered =~ "invocationContextKey"
    refute rendered =~ "memory_context_key"
    refute rendered =~ "memory_context_verified"
    refute rendered =~ "memoryContextKey"
    refute rendered =~ "invocation_proof"
    refute rendered =~ "invocationProof"
    refute rendered =~ "shared_memory_grant"
    refute rendered =~ "sharedMemoryGrant"
    refute rendered =~ "invocationMcpServers"
    refute rendered =~ "invocationToolPolicy"
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
    {run_id, [run_id]}
  end

  defp dispatch(job, :wake) do
    assert {:ok, %CronRun{id: run_id, triggered_by: :wake}} = Wake.trigger(job.id)
    {run_id, [run_id]}
  end

  defp dispatch(job, :schedule) do
    scheduled_for_ms = LemonCore.Clock.now_ms() - 1_000
    replace_job_state(%{job | next_run_at_ms: scheduled_for_ms})
    CronManager.tick()
    run_id = CronStore.scheduled_run_id(job.id, scheduled_for_ms)
    {run_id, [run_id]}
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
    run_id = CronStore.retry_run_id(source.id, 1)
    {run_id, [source.id, run_id]}
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
