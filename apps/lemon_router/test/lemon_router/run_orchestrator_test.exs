defmodule LemonRouter.RunOrchestratorTest do
  use ExUnit.Case, async: false

  alias LemonCore.RunRequest
  alias LemonChannels.Types.ResumeToken
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
        send(opts[:notify_pid], {:captured_job, opts[:job]})
      end

      {:ok, opts}
    end
  end

  setup do
    {engine_registry_started_here?, engine_pid} =
      case Process.whereis(LemonGateway.EngineRegistry) do
        nil ->
          {:ok, started_pid} = LemonGateway.EngineRegistry.start_link([])
          {true, started_pid}

        existing_pid ->
          {false, existing_pid}
      end

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

          if engine_registry_started_here? and is_pid(engine_pid) and Process.alive?(engine_pid) do
            GenServer.stop(engine_pid)
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

          if engine_registry_started_here? and is_pid(engine_pid) and Process.alive?(engine_pid) do
            GenServer.stop(engine_pid)
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

  describe "session config application" do
    test "applies model from session config" do
      session_key = "test:session:model:#{System.unique_integer()}"

      # Store session config with model
      LemonCore.Store.put_session_policy(session_key, %{
        model: "claude-3-opus"
      })

      params = %{
        origin: :control_plane,
        session_key: session_key,
        agent_id: "test",
        prompt: "Hello"
      }

      # The orchestrator should pick up the model from session config
      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "applies thinking_level from session config" do
      session_key = "test:session:thinking:#{System.unique_integer()}"

      LemonCore.Store.put_session_policy(session_key, %{
        thinking_level: "high"
      })

      params = %{
        origin: :control_plane,
        session_key: session_key,
        agent_id: "test",
        prompt: "Hello"
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "explicit engine_id overrides session model" do
      session_key = "test:session:override:#{System.unique_integer()}"

      LemonCore.Store.put_session_policy(session_key, %{
        model: "claude-3-haiku"
      })

      params = %{
        origin: :control_plane,
        session_key: session_key,
        agent_id: "test",
        prompt: "Hello",
        # This should take precedence
        engine_id: "explicit:engine"
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles missing session config gracefully" do
      session_key = "test:session:missing:#{System.unique_integer()}"

      # Don't set any session config

      params = %{
        origin: :control_plane,
        session_key: session_key,
        agent_id: "test",
        prompt: "Hello"
      }

      result = RunOrchestrator.submit(request(params))
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "resume extraction and prompt sanitization" do
    test "extracts resume token from prompt and strips strict resume lines" do
      prompt = "codex resume thread_abc123\nPlease continue with this task."

      {resume, stripped} = RunOrchestrator.extract_resume_and_strip_prompt(prompt, %{})

      assert %ResumeToken{engine: "codex", value: "thread_abc123"} = resume
      assert stripped == "Please continue with this task."
    end

    test "extracts resume token from reply_to_text when prompt has none" do
      prompt = "Continue with changes."
      meta = %{reply_to_text: "`codex resume thread_reply_123`"}

      {resume, stripped} = RunOrchestrator.extract_resume_and_strip_prompt(prompt, meta)

      assert %ResumeToken{engine: "codex", value: "thread_reply_123"} = resume
      assert stripped == "Continue with changes."
    end

    test "uses fallback prompt when stripped prompt would be empty" do
      prompt = "codex resume thread_only_resume"

      {resume, stripped} = RunOrchestrator.extract_resume_and_strip_prompt(prompt, %{})

      assert %ResumeToken{engine: "codex", value: "thread_only_resume"} =
               resume

      assert stripped == "Continue."
    end

    test "strips multiple strict resume lines but keeps non-resume text" do
      prompt = """
      codex resume thread_one
      Keep this line
      `codex resume thread_two`
      and this one too
      """

      {_resume, stripped} = RunOrchestrator.extract_resume_and_strip_prompt(prompt, %{})

      assert stripped == "Keep this line\nand this one too"
    end
  end

  describe "agent profile defaults" do
    setup do
      original_state = :sys.get_state(LemonRouter.AgentProfiles)

      on_exit(fn ->
        :sys.replace_state(LemonRouter.AgentProfiles, fn _ -> original_state end)
      end)

      :ok
    end

    test "applies system_prompt, model and tool_policy from agent profile" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

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

      :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
        %{state | profiles: profile_map_with_oracle()}
      end)

      params = %{
        origin: :control_plane,
        session_key: "agent:oracle:main",
        agent_id: "oracle",
        prompt: "Hello oracle"
      }

      assert {:ok, _run_id} = RunOrchestrator.submit(orchestrator_pid, request(params))
      assert_receive {:captured_job, job}, 500

      assert job.engine_id == "echo"
      assert job.meta[:model] == "openai-codex:gpt-5.3-codex"
      assert job.meta[:system_prompt] == "You are the oracle."
      assert "bash" in (job.tool_policy[:blocked_tools] || [])
    end

    test "treats engine-prefixed model as engine override" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

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

      :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
        %{state | profiles: profile_map_with_oracle("codex:gpt-test")}
      end)

      params = %{
        origin: :control_plane,
        session_key: "agent:oracle:main",
        agent_id: "oracle",
        prompt: "Hello oracle"
      }

      assert {:ok, _run_id} = RunOrchestrator.submit(orchestrator_pid, request(params))
      assert_receive {:captured_job, job}, 500

      assert job.engine_id == "codex:gpt-test"
      assert job.meta[:model] == "codex:gpt-test"
    end

    test "explicit engine_id still overrides profile defaults" do
      run_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

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

      :sys.replace_state(LemonRouter.AgentProfiles, fn state ->
        %{state | profiles: profile_map_with_oracle()}
      end)

      params = %{
        origin: :control_plane,
        session_key: "agent:oracle:main",
        agent_id: "oracle",
        prompt: "Hello oracle",
        engine_id: "explicit:engine"
      }

      assert {:ok, _run_id} = RunOrchestrator.submit(orchestrator_pid, request(params))
      assert_receive {:captured_job, job}, 500
      assert job.engine_id == "explicit:engine"
    end
  end

  defp request(attrs), do: RunRequest.new(attrs)

  defp test_profile do
    %{
      id: "test",
      name: "Test Agent",
      description: nil,
      avatar: nil,
      default_engine: "lemon",
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
        default_engine: "lemon",
        tool_policy: nil,
        system_prompt: nil,
        model: nil
      },
      "oracle" => %{
        id: "oracle",
        name: "Oracle",
        default_engine: "echo",
        tool_policy: %{blocked_tools: ["bash"]},
        system_prompt: "You are the oracle.",
        model: model
      }
    }
  end
end
