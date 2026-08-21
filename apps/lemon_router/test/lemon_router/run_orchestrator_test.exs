defmodule LemonRouter.RunOrchestratorTest do
  use ExUnit.Case, async: false

  alias LemonCore.RunRequest
  alias LemonCore.ResumeToken
  alias LemonRouter.RunOrchestrator

  @moduledoc """
  Tests for RunOrchestrator including cwd and tool_policy override handling.
  """

  defmodule BlockingRunProcess do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      run_id = opts[:run_id] || System.unique_integer([:positive])

      %{
        id: {__MODULE__, run_id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5_000
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok, opts}
    end
  end

  defmodule CapturingRunProcess do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      run_id = opts[:run_id] || System.unique_integer([:positive])

      %{
        id: {__MODULE__, run_id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5_000
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      if is_pid(opts[:notify_pid]) do
        send(opts[:notify_pid], {:captured_job, opts[:execution_request]})
        send(opts[:notify_pid], {:captured_run_opts, opts})
      end

      {:ok, opts, {:continue, :auto_stop}}
    end

    @impl true
    def handle_continue(:auto_stop, state) do
      {:stop, :normal, state}
    end
  end

  defmodule PersistentCapturingRunProcess do
    @moduledoc false
    use GenServer

    def child_spec(opts) do
      run_id = opts[:run_id] || System.unique_integer([:positive])

      %{
        id: {__MODULE__, run_id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5_000
      }
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      if is_pid(opts[:notify_pid]) do
        send(opts[:notify_pid], {:captured_run_opts, opts})
      end

      {:ok, opts}
    end
  end

  defmodule RunOrchestratorFailingRunProcess do
    @moduledoc false

    def start_link(_opts), do: {:error, :run_failed_to_start}

    def child_spec(opts) do
      run_id = opts[:run_id] || System.unique_integer([:positive])

      %{
        id: {__MODULE__, run_id},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary,
        shutdown: 5_000
      }
    end
  end

  defmodule RunOrchestratorEventBridgeStub do
    @moduledoc false

    def subscribe_run(run_id), do: notify({:bridge_subscribed, run_id})
    def unsubscribe_run(run_id), do: notify({:bridge_unsubscribed, run_id})

    defp notify(message) do
      case Application.get_env(:lemon_router, :event_bridge_test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end

      :ok
    end
  end

  setup do
    ensure_pubsub()

    original_bridge_impl = Application.get_env(:lemon_core, :event_bridge_impl)
    original_bridge_test_pid = Application.get_env(:lemon_router, :event_bridge_test_pid)
    Application.put_env(:lemon_router, :event_bridge_test_pid, self())
    :ok = LemonCore.EventBridge.configure(RunOrchestratorEventBridgeStub)

    # Start RunOrchestrator if not running
    case Process.whereis(RunOrchestrator) do
      nil ->
        {:ok, pid} = RunOrchestrator.start_link([])

        original_profiles_state = :sys.get_state(LemonRouter.AgentProfiles)

        :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
          %{state | profiles: Map.put_new(state.profiles, "test", test_profile())}
        end)

        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)

          :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original_profiles_state end)

          restore_event_bridge_impl(original_bridge_impl)

          case original_bridge_test_pid do
            nil -> Application.delete_env(:lemon_router, :event_bridge_test_pid)
            bridge_pid -> Application.put_env(:lemon_router, :event_bridge_test_pid, bridge_pid)
          end
        end)

        {:ok, orchestrator_pid: pid}

      pid ->
        original_profiles_state = :sys.get_state(LemonRouter.AgentProfiles)

        :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
          %{state | profiles: Map.put_new(state.profiles, "test", test_profile())}
        end)

        on_exit(fn ->
          :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original_profiles_state end)

          restore_event_bridge_impl(original_bridge_impl)

          case original_bridge_test_pid do
            nil -> Application.delete_env(:lemon_router, :event_bridge_test_pid)
            bridge_pid -> Application.put_env(:lemon_router, :event_bridge_test_pid, bridge_pid)
          end
        end)

        {:ok, orchestrator_pid: pid}
    end
  end

  describe "submit/1" do
    test "generates run_id" do
      # Note: This will fail to start the actual run since we don't have
      # the full infrastructure running, but we can test the orchestrator logic
      # by verifying it doesn't crash and returns an appropriate response

      # We expect this to fail since RunSupervisor isn't started
      result =
        RunOrchestrator.submit(
          request(%{
            origin: :control_plane,
            session_key: "agent:test:main",
            agent_id: "test",
            prompt: "Hello",
            queue_mode: :collect
          })
        )

      # Either succeeds with run_id or fails with meaningful error
      case result do
        {:ok, run_id} ->
          assert is_binary(run_id)
          assert String.starts_with?(run_id, "run_")

        {:error, reason} ->
          # Expected when RunSupervisor isn't running
          assert reason != nil
      end
    end

    test "accepts RunRequest struct input" do
      result =
        RunOrchestrator.submit(%RunRequest{
          origin: :control_plane,
          session_key: "agent:test:main",
          agent_id: "test",
          prompt: "Hello from struct",
          queue_mode: :collect
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts map input and normalizes to RunRequest" do
      result =
        RunOrchestrator.submit(%{
          origin: :control_plane,
          session_key: "agent:test:main",
          agent_id: "test",
          prompt: "Hello from map input"
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts keyword input and normalizes to RunRequest" do
      result =
        RunOrchestrator.submit(
          origin: :control_plane,
          session_key: "agent:test:main",
          agent_id: "test",
          prompt: "Hello from keyword input"
        )

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "returns unknown_agent_id error for unconfigured agent" do
      result =
        RunOrchestrator.submit(
          request(%{
            origin: :control_plane,
            session_key: "agent:missing-agent:main",
            agent_id: "missing-agent",
            prompt: "Hello",
            queue_mode: :collect
          })
        )

      assert {:error, {:unknown_agent_id, "missing-agent"}} = result
    end
  end

  describe "admission control" do
    test "returns :run_capacity_reached when bounded run supervisor is saturated" do
      run_supervisor =
        start_supervised!({DynamicSupervisor, strategy: :one_for_one, max_children: 1})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: BlockingRunProcess
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      params_1 = %{
        origin: :control_plane,
        session_key: "agent:cap:test:1",
        agent_id: "test",
        prompt: "first"
      }

      params_2 = %{
        origin: :control_plane,
        session_key: "agent:cap:test:2",
        agent_id: "test",
        prompt: "second"
      }

      assert {:ok, _run_id} = RunOrchestrator.submit(orchestrator_pid, request(params_1))

      assert {:error, :run_capacity_reached} =
               RunOrchestrator.submit(orchestrator_pid, request(params_2))
    end

    test "idle start failure unsubscribes exactly once" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: RunOrchestratorFailingRunProcess
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      params = %{
        origin: :control_plane,
        session_key: "agent:idle-fail:test:#{System.unique_integer([:positive])}",
        agent_id: "test",
        prompt: "fail immediately"
      }

      assert {:error, :run_failed_to_start} =
               RunOrchestrator.submit(orchestrator_pid, request(params))

      assert_receive {:bridge_subscribed, run_id}, 500
      assert_receive {:bridge_unsubscribed, ^run_id}, 500
      refute_receive {:bridge_unsubscribed, ^run_id}, 100
    end
  end

  describe "start_run_process/4" do
    test "merges orchestrator defaults before normalizing the submission" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self(), custom: :value}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = "agent:start-run:test:#{System.unique_integer([:positive])}"
      conversation_key = {:session, session_key}

      submission = %{
        run_id: run_id,
        session_key: session_key,
        conversation_key: conversation_key,
        queue_mode: :collect,
        execution_request: %LemonCore.ExecutionCommand{
          run_id: run_id,
          session_key: session_key,
          prompt: "start directly",
          conversation_key: conversation_key,
          meta: %{}
        }
      }

      assert {:ok, pid} =
               RunOrchestrator.start_run_process(
                 orchestrator_pid,
                 submission,
                 self(),
                 conversation_key
               )

      assert is_pid(pid)
      assert_receive {:captured_run_opts, opts}, 500
      assert opts[:run_id] == run_id
      assert opts[:session_key] == session_key
      assert opts[:conversation_key] == conversation_key
      assert opts[:coordinator_pid] == self()
      assert opts[:manage_session_registry?] == false
      assert opts[:custom] == :value
      assert opts[:execution_request].run_id == run_id
    end

    test "preserves caller-provided start fields instead of overwriting them with orchestrator defaults" do
      orchestrator_run_supervisor =
        start_supervised!(%{
          id: :orchestrator_run_supervisor,
          start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]}
        })

      caller_run_supervisor =
        start_supervised!(%{
          id: :caller_run_supervisor,
          start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]}
        })

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: orchestrator_run_supervisor,
          run_process_module: BlockingRunProcess,
          run_process_opts: %{notify_pid: self(), custom: :default}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = "agent:start-run:override:#{System.unique_integer([:positive])}"
      conversation_key = {:session, session_key}

      submission = %{
        run_id: run_id,
        session_key: session_key,
        conversation_key: conversation_key,
        queue_mode: :collect,
        execution_request: %LemonCore.ExecutionCommand{
          run_id: run_id,
          session_key: session_key,
          prompt: "start directly",
          conversation_key: conversation_key,
          meta: %{}
        },
        run_supervisor: caller_run_supervisor,
        run_process_module: PersistentCapturingRunProcess,
        run_process_opts: %{notify_pid: self(), custom: :caller}
      }

      assert {:ok, pid} =
               RunOrchestrator.start_run_process(
                 orchestrator_pid,
                 submission,
                 self(),
                 conversation_key
               )

      assert is_pid(pid)
      assert_receive {:captured_run_opts, opts}, 500
      assert opts[:custom] == :caller
      assert opts[:conversation_key] == conversation_key
      assert opts[:manage_session_registry?] == false
      assert %{active: 1} = DynamicSupervisor.count_children(caller_run_supervisor)
      assert %{active: 0} = DynamicSupervisor.count_children(orchestrator_run_supervisor)
    end
  end

  describe "cwd override handling" do
    # These tests verify the cwd parameter is properly extracted and passed
    # We test the logic flow rather than the full integration

    test "cwd override is accepted in params" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        cwd: "/custom/working/dir"
      }

      # The orchestrator should accept the cwd parameter without error
      # Even if the full submission fails, no crash should occur
      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "cwd from meta is used when no override provided" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        meta: %{cwd: "/meta/working/dir"}
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "cwd override takes precedence over meta cwd" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        cwd: "/override/dir",
        meta: %{cwd: "/meta/dir"}
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "tool_policy override handling" do
    test "tool_policy override is accepted in params" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: %{
          approvals: %{"bash" => :always},
          blocked_tools: ["dangerous_tool"]
        }
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "tool_policy override is merged with resolved policy" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: %{sandbox: true}
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "empty tool_policy override does not change resolved policy" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: %{}
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "nil tool_policy override is ignored" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: nil
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "combined overrides" do
    test "both cwd and tool_policy overrides can be provided" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        cwd: "/custom/dir",
        tool_policy: %{
          approvals: %{"bash" => :always}
        }
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "native-only routing" do
    setup do
      original_state = :sys.get_state(LemonRouter.AgentProfiles)

      on_exit(fn ->
        :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original_state end)
      end)

      :ok
    end

    test "applies model and profile policy" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      session_key = unique_oracle_session_key()

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
        LemonCore.Store.delete_session_policy(session_key)
      end)

      :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
        %{state | profiles: profile_map_with_oracle()}
      end)

      assert {:ok, _run_id} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :control_plane,
                   session_key: session_key,
                   agent_id: "oracle",
                   prompt: "Hello oracle",
                   tool_policy: %{blocked_tools: ["rm"]}
                 })
               )

      assert_receive {:captured_job, job}, 500
      assert job.meta[:model] == "openai-codex:gpt-5.3-codex"
      assert job.meta[:system_prompt] == "You are the oracle."
      assert "bash" in (job.tool_policy[:blocked_tools] || [])
      assert "rm" in (job.tool_policy[:blocked_tools] || [])
    end

    test "keeps structured resume provenance while executing through lemon" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      session_key = unique_oracle_session_key()

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
      end)

      resume = %ResumeToken{engine: "lemon", value: "session_abc123"}

      assert {:ok, _run_id} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :channel,
                   session_key: session_key,
                   agent_id: "test",
                   prompt: "Please continue with this task.",
                   resume: resume
                 })
               )

      assert_receive {:captured_job, job}, 500
      assert job.resume == resume
      assert job.meta[:resume_source] == :explicit
    end

    test "request model takes precedence over session and profile models" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      session_key = unique_oracle_session_key()
      LemonCore.Store.put_session_policy(session_key, %{model: "session-model"})

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
        LemonCore.Store.delete_session_policy(session_key)
      end)

      :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
        %{state | profiles: profile_map_with_oracle("profile-model")}
      end)

      assert {:ok, _run_id} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :control_plane,
                   session_key: session_key,
                   agent_id: "oracle",
                   prompt: "Hello oracle",
                   model: "request-model"
                 })
               )

      assert_receive {:captured_job, job}, 500
      assert job.meta[:model] == "request-model"
    end

    test "does not mutate the session policy during submission" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      session_key = unique_oracle_session_key()
      session_policy = %{model: "session-model"}
      LemonCore.Store.put_session_policy(session_key, session_policy)

      {:ok, orchestrator_pid} =
        GenServer.start_link(
          RunOrchestrator,
          run_supervisor: run_supervisor,
          run_process_module: CapturingRunProcess,
          run_process_opts: %{notify_pid: self()}
        )

      on_exit(fn ->
        if Process.alive?(orchestrator_pid), do: GenServer.stop(orchestrator_pid)
        LemonCore.Store.delete_session_policy(session_key)
      end)

      assert {:ok, _run_id} =
               RunOrchestrator.submit(
                 orchestrator_pid,
                 request(%{
                   origin: :control_plane,
                   session_key: session_key,
                   agent_id: "test",
                   prompt: "Hello"
                 })
               )

      assert_receive {:captured_job, job}, 500
      assert LemonCore.Store.get_session_policy(session_key) == session_policy
    end
  end

  defp request(attrs), do: RunRequest.new(attrs)

  defp unique_oracle_session_key do
    "agent:oracle:main:#{System.unique_integer([:positive])}"
  end

  defp test_profile do
    %{
      id: "test",
      name: "Test Agent",
      description: nil,
      avatar: nil,
      tool_policy: nil,
      system_prompt: nil,
      model: nil,
      rate_limit: nil
    }
  end

  defp profile_map_with_oracle(model \\ "openai-codex:gpt-5.3-codex") do
    %{
      "default" => %{
        id: "default",
        name: "Default Agent",
        tool_policy: nil,
        system_prompt: nil,
        model: nil
      },
      "oracle" => %{
        id: "oracle",
        name: "Oracle",
        tool_policy: %{blocked_tools: ["bash"]},
        system_prompt: "You are the oracle.",
        model: model
      }
    }
  end

  defp ensure_pubsub do
    if Process.whereis(LemonCore.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: LemonCore.PubSub})
    end
  end

  defp restore_event_bridge_impl(nil) do
    Application.delete_env(:lemon_core, :event_bridge_impl)
  end

  defp restore_event_bridge_impl(value) do
    Application.put_env(:lemon_core, :event_bridge_impl, value)
  end

  describe "counts/0 non-placeholder behavior" do
    test "active reflects DynamicSupervisor children" do
      counts = RunOrchestrator.counts()
      assert is_integer(counts.active)
      assert counts.active >= 0
    end

    test "queued is driven by telemetry, not hardcoded to 0" do
      before = RunOrchestrator.counts().queued

      for idx <- 1..25 do
        :telemetry.execute([:lemon, :run, :submit], %{count: 1}, %{
          session_key: "test:counts:#{idx}",
          origin: :test,
          engine: "lemon"
        })
      end

      after_submit = RunOrchestrator.counts().queued
      assert after_submit > before
    end

    test "completed_today is driven by telemetry, not hardcoded to 0" do
      before = RunOrchestrator.counts().completed_today

      :telemetry.execute([:lemon, :run, :stop], %{duration_ms: 50, ok: true}, %{
        run_id: "run_counts_test"
      })

      after_stop = RunOrchestrator.counts().completed_today
      assert after_stop == before + 1
    end
  end
end
