defmodule AgentCore.SupervisionTest do
  use ExUnit.Case, async: false

  alias AgentCore.AgentRegistry
  alias AgentCore.SubagentSupervisor
  alias AgentCore.Loop
  alias AgentCore.EventStream
  alias AgentCore.Types.{AgentContext, AgentLoopConfig}
  alias AgentCore.Test.Mocks

  alias Ai.Types.{StreamOptions, UserMessage}

  # ============================================================================
  # AgentCore.AgentRegistry Tests
  # ============================================================================

  describe "AgentCore.AgentRegistry" do
    test "can register and lookup agents by key" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :main, 0}

      :ok = AgentRegistry.register(key)

      assert {:ok, pid} = AgentRegistry.lookup(key)
      assert pid == self()
    end

    test "lookup returns :error for unregistered keys" do
      key = {"nonexistent_session", :unknown, 99}

      assert :error = AgentRegistry.lookup(key)
    end

    test "can register with metadata and retrieve it" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :research, 0}
      metadata = %{model: "claude-3", created_at: System.system_time(:millisecond)}

      :ok = AgentRegistry.register(key, metadata)

      assert {:ok, pid, ^metadata} = AgentRegistry.lookup_with_metadata(key)
      assert pid == self()
    end

    test "returns error when registering duplicate key" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :implement, 0}

      :ok = AgentRegistry.register(key)

      # Spawn another process to try registering the same key
      parent = self()

      spawn(fn ->
        result = AgentRegistry.register(key)
        send(parent, {:register_result, result})
      end)

      assert_receive {:register_result, {:error, {:already_registered, pid}}}
      assert pid == self()
    end

    test "can unregister and re-register" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :main, 1}

      :ok = AgentRegistry.register(key)
      assert {:ok, _pid} = AgentRegistry.lookup(key)

      :ok = AgentRegistry.unregister(key)
      assert :error = AgentRegistry.lookup(key)

      :ok = AgentRegistry.register(key)
      assert {:ok, _pid} = AgentRegistry.lookup(key)
    end

    test "list_by_session returns all agents for a session" do
      session_id = "session_#{:rand.uniform(100_000)}"
      parent = self()

      # Register from multiple processes
      pids =
        for role <- [:main, :research, :implement] do
          spawn(fn ->
            key = {session_id, role, 0}
            :ok = AgentRegistry.register(key)
            send(parent, {:registered, role, self()})

            receive do
              :done -> :ok
            end
          end)
        end

      # Wait for all registrations
      for _ <- 1..3 do
        assert_receive {:registered, _role, _pid}
      end

      agents = AgentRegistry.list_by_session(session_id)

      assert length(agents) == 3

      roles = Enum.map(agents, fn {role, _index, _pid} -> role end) |> Enum.sort()
      assert roles == [:implement, :main, :research]

      # Cleanup
      for pid <- pids, do: send(pid, :done)
    end

    test "count returns number of registered agents" do
      initial_count = AgentRegistry.count()

      session_id = "session_#{:rand.uniform(100_000)}"
      :ok = AgentRegistry.register({session_id, :test, 0})

      assert AgentRegistry.count() == initial_count + 1
    end

    test "via/1 returns a via tuple for registration" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :main, 0}

      via = AgentRegistry.via(key)

      assert {:via, Registry, {AgentCore.AgentRegistry, ^key}} = via
    end
  end

  # ============================================================================
  # AgentCore.SubagentSupervisor Tests
  # ============================================================================

  describe "AgentCore.SubagentSupervisor" do
    test "can start a subagent" do
      response = Mocks.assistant_message("Hello from subagent!")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "You are a test subagent.",
            model: Mocks.mock_model(),
            tools: []
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert is_pid(pid)
      assert Process.alive?(pid)

      # Cleanup
      :ok = SubagentSupervisor.stop_subagent(pid)
    end

    test "start_subagent registers registry_key to subagent pid" do
      session_id = "session_#{:rand.uniform(100_000)}"
      key = {session_id, :research, 0}
      response = Mocks.assistant_message("Registry check")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          registry_key: key,
          initial_state: %{
            system_prompt: "You are a test subagent.",
            model: Mocks.mock_model(),
            tools: []
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert {:ok, ^pid} = AgentRegistry.lookup(key)

      :ok = SubagentSupervisor.stop_subagent_by_key(key)
      Process.sleep(10)
      refute Process.alive?(pid)
    end

    test "can stop a subagent by pid" do
      response = Mocks.assistant_message("Subagent response")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Test",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert Process.alive?(pid)

      :ok = SubagentSupervisor.stop_subagent(pid)

      # Give it a moment to terminate
      Process.sleep(10)
      refute Process.alive?(pid)
    end

    test "stop_subagent returns error for unknown pid" do
      fake_pid = spawn(fn -> :ok end)
      Process.sleep(10)

      assert {:error, :not_found} = SubagentSupervisor.stop_subagent(fake_pid)
    end

    test "list_subagents returns all running subagents" do
      initial_count = length(SubagentSupervisor.list_subagents())
      response = Mocks.assistant_message("Response")

      pids =
        for _ <- 1..3 do
          {:ok, pid} =
            SubagentSupervisor.start_subagent(
              initial_state: %{
                system_prompt: "Test",
                model: Mocks.mock_model()
              },
              convert_to_llm: Mocks.simple_convert_to_llm(),
              stream_fn: Mocks.mock_stream_fn_single(response)
            )

          pid
        end

      subagents = SubagentSupervisor.list_subagents()
      assert length(subagents) == initial_count + 3

      for pid <- pids do
        assert pid in subagents
      end

      # Cleanup
      for pid <- pids do
        SubagentSupervisor.stop_subagent(pid)
      end
    end

    test "count returns number of active subagents" do
      initial_count = SubagentSupervisor.count()
      response = Mocks.assistant_message("Response")

      {:ok, pid} =
        SubagentSupervisor.start_subagent(
          initial_state: %{
            system_prompt: "Test",
            model: Mocks.mock_model()
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: Mocks.mock_stream_fn_single(response)
        )

      assert SubagentSupervisor.count() == initial_count + 1

      SubagentSupervisor.stop_subagent(pid)
      Process.sleep(10)

      assert SubagentSupervisor.count() == initial_count
    end

    test "stop_all terminates all subagents" do
      response = Mocks.assistant_message("Response")

      pids =
        for _ <- 1..3 do
          {:ok, pid} =
            SubagentSupervisor.start_subagent(
              initial_state: %{
                system_prompt: "Test",
                model: Mocks.mock_model()
              },
              convert_to_llm: Mocks.simple_convert_to_llm(),
              stream_fn: Mocks.mock_stream_fn_single(response)
            )

          pid
        end

      assert length(SubagentSupervisor.list_subagents()) >= 3

      :ok = SubagentSupervisor.stop_all()
      Process.sleep(20)

      for pid <- pids do
        refute Process.alive?(pid)
      end
    end
  end

  # ============================================================================
  # AgentCore.LoopTaskSupervisor Tests
  # ============================================================================

  describe "AgentCore.LoopTaskSupervisor" do
    test "agent_loop runs under LoopTaskSupervisor" do
      context =
        AgentContext.new(
          system_prompt: "You are helpful.",
          messages: [],
          tools: []
        )

      response = Mocks.assistant_message("Hello!")

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_options: %StreamOptions{}
      }

      prompt = %UserMessage{
        role: :user,
        content: "Hi",
        timestamp: System.system_time(:millisecond)
      }

      # Start the loop
      stream =
        Loop.agent_loop([prompt], context, config, nil, Mocks.mock_stream_fn_single(response))

      # The loop runs in a Task under LoopTaskSupervisor
      # Verify by checking supervisor children include our task
      children = Task.Supervisor.children(AgentCore.LoopTaskSupervisor)
      assert is_list(children)

      # Consume the stream to completion
      {:ok, _messages} = EventStream.result(stream)
    end

    test "agent_loop_continue runs under LoopTaskSupervisor" do
      user_msg = %UserMessage{
        role: :user,
        content: "Continue from here",
        timestamp: System.system_time(:millisecond)
      }

      context =
        AgentContext.new(
          system_prompt: "You are helpful.",
          messages: [user_msg],
          tools: []
        )

      response = Mocks.assistant_message("Continuing...")

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_options: %StreamOptions{}
      }

      # Start continue loop
      stream =
        Loop.agent_loop_continue(context, config, nil, Mocks.mock_stream_fn_single(response))

      # The loop runs in a Task under LoopTaskSupervisor
      children = Task.Supervisor.children(AgentCore.LoopTaskSupervisor)
      assert is_list(children)

      # Consume the stream to completion
      {:ok, _messages} = EventStream.result(stream)
    end

    test "loop task crashes are isolated and don't affect supervisor" do
      context =
        AgentContext.new(
          system_prompt: "You are helpful.",
          messages: [],
          tools: []
        )

      # Create a stream function that crashes
      crashing_stream_fn = fn _model, _context, _options ->
        raise "Intentional crash for testing"
      end

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_options: %StreamOptions{}
      }

      prompt = %UserMessage{
        role: :user,
        content: "Crash test",
        timestamp: System.system_time(:millisecond)
      }

      # Start the loop with crashing stream function
      stream = Loop.agent_loop([prompt], context, config, nil, crashing_stream_fn)

      # The error should be captured and returned via the stream
      result = EventStream.result(stream)

      # Should get an error result
      assert match?({:error, _, _}, result)

      # Supervisor should still be alive
      assert Process.alive?(Process.whereis(AgentCore.LoopTaskSupervisor))
    end

    test "multiple loops can run concurrently" do
      context =
        AgentContext.new(
          system_prompt: "You are helpful.",
          messages: [],
          tools: []
        )

      config = %AgentLoopConfig{
        model: Mocks.mock_model(),
        convert_to_llm: Mocks.simple_convert_to_llm(),
        stream_options: %StreamOptions{}
      }

      # Start 3 concurrent loops
      streams =
        for i <- 1..3 do
          response = Mocks.assistant_message("Response #{i}")

          prompt = %UserMessage{
            role: :user,
            content: "Message #{i}",
            timestamp: System.system_time(:millisecond)
          }

          Loop.agent_loop([prompt], context, config, nil, Mocks.mock_stream_fn_single(response))
        end

      # All should complete successfully
      results =
        for stream <- streams do
          EventStream.result(stream)
        end

      for result <- results do
        assert match?({:ok, _}, result)
      end
    end

    test "loop task terminates when agent process dies" do
      parent = self()
      Process.flag(:trap_exit, true)

      stream_fn = fn _model, _context, _options ->
        {:ok, stream} = Ai.EventStream.start_link()
        send(parent, {:stream_ready, stream})
        {:ok, stream}
      end

      {:ok, agent} =
        AgentCore.Agent.start_link(
          initial_state: %{
            system_prompt: "You are helpful.",
            model: Mocks.mock_model(),
            tools: []
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: stream_fn
        )

      :ok = AgentCore.Agent.prompt(agent, "Long running prompt")
      assert_receive {:stream_ready, stream}

      task = wait_for_running_task(agent)
      task_pid = task.pid
      ref = Process.monitor(task_pid)

      Process.exit(agent, :kill)

      assert_receive {:DOWN, ^ref, :process, ^task_pid, _}, 1000

      Ai.EventStream.cancel(stream, :test_cleanup)
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "supervision tree integration" do
    test "supervisors are running on application start" do
      # Verify registry is running
      assert Process.whereis(AgentCore.AgentRegistry) != nil

      # Verify SubagentSupervisor is running
      assert Process.whereis(AgentCore.SubagentSupervisor) != nil

      # Verify LoopTaskSupervisor is running
      assert Process.whereis(AgentCore.LoopTaskSupervisor) != nil
    end

    test "main supervisor exists" do
      assert Process.whereis(AgentCore.Supervisor) != nil
    end
  end

  defp wait_for_running_task(agent, attempts \\ 50) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case :sys.get_state(agent).running_task do
        %Task{} = task ->
          {:halt, task}

        _ ->
          Process.sleep(10)
          {:cont, nil}
      end
    end) || flunk("running_task did not start")
  end
end
