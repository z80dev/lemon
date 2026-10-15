defmodule LemonAgent.SupervisionTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Loop
  alias LemonAgent.EventStream
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}
  alias LemonAgent.Test.Mocks

  alias LemonAi.Types.{StreamOptions, UserMessage}

  # ============================================================================
  # LemonAgent.LoopTaskSupervisor Tests
  # ============================================================================

  describe "LemonAgent.LoopTaskSupervisor" do
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
      assert Process.alive?(Process.whereis(LemonAgent.LoopTaskSupervisor))
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
        {:ok, stream} = LemonAi.EventStream.start_link()
        send(parent, {:stream_ready, stream})
        {:ok, stream}
      end

      {:ok, agent} =
        LemonAgent.Agent.start_link(
          initial_state: %{
            system_prompt: "You are helpful.",
            model: Mocks.mock_model(),
            tools: []
          },
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_fn: stream_fn
        )

      :ok = LemonAgent.Agent.prompt(agent, "Long running prompt")
      assert_receive {:stream_ready, stream}

      task = wait_for_running_task(agent)
      task_pid = task.pid
      ref = Process.monitor(task_pid)

      Process.exit(agent, :kill)

      assert_receive {:DOWN, ^ref, :process, ^task_pid, _}, 1000

      LemonAi.EventStream.cancel(stream, :test_cleanup)
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "supervision tree integration" do
    test "supervisors are running on application start" do
      # Verify registry is running
      assert Process.whereis(LemonAgent.AgentRegistry) != nil

      # Verify SubagentSupervisor is running
      assert Process.whereis(LemonAgent.SubagentSupervisor) != nil

      # Verify LoopTaskSupervisor is running
      assert Process.whereis(LemonAgent.LoopTaskSupervisor) != nil
    end

    test "main supervisor exists" do
      assert Process.whereis(LemonAgent.Supervisor) != nil
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
