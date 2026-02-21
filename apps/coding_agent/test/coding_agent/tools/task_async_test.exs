defmodule CodingAgent.Tools.TaskAsyncTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Task
  alias CodingAgent.TaskStore
  alias CodingAgent.RunGraph
  alias LemonCore.RunRequest

  defmodule StubRunOrchestrator do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{owner: nil, count: 0} end, name: __MODULE__)
    end

    def configure(owner) when is_pid(owner) do
      Agent.update(__MODULE__, fn _ -> %{owner: owner, count: 0} end)
    end

    def submit(%RunRequest{} = request) do
      Agent.get_and_update(__MODULE__, fn %{owner: owner, count: count} = state ->
        next = count + 1

        if is_pid(owner) do
          send(owner, {:router_submit, request, next})
        end

        {{:ok, "run_stub_#{next}"}, %{state | count: next}}
      end)
    end
  end

  defmodule SessionSpy do
    def follow_up(pid, text) do
      send(pid, {:session_follow_up, text})
      :ok
    end
  end

  setup do
    start_supervised!(StubRunOrchestrator)
    StubRunOrchestrator.configure(self())

    # Clear stores before each test
    try do
      TaskStore.clear()
    catch
      _, _ -> :ok
    end

    try do
      RunGraph.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  describe "execute/6 - async auto followup" do
    test "posts completion into the live session when session pid is available" do
      result =
        Task.execute(
          "call_live_followup",
          %{
            "description" => "Live followup task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "task output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: SessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: StubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"

      assert_receive {:session_follow_up, text}, 1_000
      assert text =~ "[task #{result.details.task_id}]"
      assert text =~ "Live followup task"
      assert text =~ "task output"
      refute_receive {:router_submit, %RunRequest{}, _}, 150
    end

    test "falls back to router followup when session pid is unavailable" do
      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}

      result =
        Task.execute(
          "call_router_followup",
          %{
            "description" => "Router followup task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "router output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: SessionSpy,
          session_pid: dead_pid,
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: StubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"

      assert_receive {:router_submit, %RunRequest{queue_mode: :followup} = followup, 1}, 1_000
      assert followup.session_key == "agent:main:main"
      assert followup.agent_id == "main"
      assert followup.prompt =~ "Router followup task"
      assert followup.prompt =~ "router output"
    end

    test "does not send followup when auto_followup is false" do
      _result =
        Task.execute(
          "call_no_followup",
          %{
            "description" => "No followup task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => false
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "silent output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: SessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: StubRunOrchestrator
        )

      refute_receive {:session_follow_up, _text}, 200
      refute_receive {:router_submit, %RunRequest{}, _}, 200
    end
  end

  describe "execute/6 - async: true" do
    test "returns task_id when async is true" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Async test task",
            "prompt" => "Return hello",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"
      assert is_binary(result.details.task_id)
      assert is_binary(result.details.run_id)
    end

    test "creates task in TaskStore when async" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Async store test",
            "prompt" => "Test prompt",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      task_id = result.details.task_id
      assert {:ok, record, _events} = TaskStore.get(task_id)
      assert record.status in [:queued, :running]
      assert record.description == "Async store test"
    end

    test "creates run in RunGraph when async" do
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Async graph test",
            "prompt" => "Test prompt",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      run_id = result.details.run_id
      assert {:ok, record} = RunGraph.get(run_id)
      assert record.status == :queued
      assert record.type == :task
    end
  end

  describe "execute/6 - poll action" do
    test "poll returns error when task_id is missing" do
      result =
        Task.execute(
          "call_1",
          %{"action" => "poll"},
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "task_id is required for action=poll"} = result
    end

    test "poll returns error for unknown task_id" do
      result =
        Task.execute(
          "call_1",
          %{
            "action" => "poll",
            "task_id" => "unknown_task_12345"
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Unknown task_id: unknown_task_12345"} = result
    end

    test "poll returns task status for existing task" do
      # First create an async task
      create_result =
        Task.execute(
          "call_1",
          %{
            "description" => "Poll test task",
            "prompt" => "Test prompt",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      task_id = create_result.details.task_id

      # Now poll for it
      poll_result =
        Task.execute(
          "call_2",
          %{
            "action" => "poll",
            "task_id" => task_id
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert %AgentCore.Types.AgentToolResult{} = poll_result
      assert poll_result.details.status in ["queued", "running", "completed"]
      assert poll_result.details.task_id == task_id
    end
  end

  describe "execute/6 - join action validation" do
    test "join returns error when task_ids is missing" do
      result =
        Task.execute(
          "call_1",
          %{"action" => "join"},
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "task_ids is required for action=join"} = result
    end

    test "join returns error when task_ids is empty list" do
      result =
        Task.execute(
          "call_1",
          %{
            "action" => "join",
            "task_ids" => []
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "task_ids is required for action=join"} = result
    end

    test "join returns error when task_ids contains non-strings" do
      result =
        Task.execute(
          "call_1",
          %{
            "action" => "join",
            "task_ids" => ["valid_id", 123, "another"]
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "task_ids must be a list of strings"} = result
    end

    # timeout_ms validation tests removed: join should not time out.

    test "join accepts task_id as single string" do
      # Create a task first
      create_result =
        Task.execute(
          "call_1",
          %{
            "description" => "Join single test",
            "prompt" => "Test",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      task_id = create_result.details.task_id

      # Join with single task_id (not in array)
      result =
        Task.execute(
          "call_2",
          %{
            "action" => "join",
            "task_id" => task_id,
            "timeout_ms" => 100
          },
          nil,
          nil,
          "/tmp",
          []
        )

      # Should timeout since task is still queued
      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status in ["timeout", "completed"]
    end

    test "join accepts task_ids as array" do
      # Create two tasks
      result1 =
        Task.execute(
          "call_1",
          %{
            "description" => "Join multi test 1",
            "prompt" => "Test 1",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      result2 =
        Task.execute(
          "call_2",
          %{
            "description" => "Join multi test 2",
            "prompt" => "Test 2",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      task_ids = [result1.details.task_id, result2.details.task_id]

      result =
        Task.execute(
          "call_3",
          %{
            "action" => "join",
            "task_ids" => task_ids,
            "timeout_ms" => 100
          },
          nil,
          nil,
          "/tmp",
          []
        )

      # Should timeout since tasks are still queued
      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status in ["timeout", "completed"]
    end
  end

  describe "execute/6 - join action modes" do
    test "join with wait_all mode" do
      # Create two tasks
      result1 =
        Task.execute(
          "call_1",
          %{
            "description" => "Wait all test 1",
            "prompt" => "Test 1",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      result2 =
        Task.execute(
          "call_2",
          %{
            "description" => "Wait all test 2",
            "prompt" => "Test 2",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      task_ids = [result1.details.task_id, result2.details.task_id]

      join_result =
        Task.execute(
          "call_3",
          %{
            "action" => "join",
            "task_ids" => task_ids,
            "mode" => "wait_all",
            "timeout_ms" => 100
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert %AgentCore.Types.AgentToolResult{} = join_result
      assert join_result.details.status in ["timeout", "completed"]

      case join_result.details.status do
        "timeout" -> assert join_result.details.snapshot.mode == :wait_all
        "completed" -> assert join_result.details.mode == "wait_all"
      end
    end

    test "join with wait_any mode" do
      # Create two tasks
      result1 =
        Task.execute(
          "call_1",
          %{
            "description" => "Wait any test 1",
            "prompt" => "Test 1",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      result2 =
        Task.execute(
          "call_2",
          %{
            "description" => "Wait any test 2",
            "prompt" => "Test 2",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      task_ids = [result1.details.task_id, result2.details.task_id]

      join_result =
        Task.execute(
          "call_3",
          %{
            "action" => "join",
            "task_ids" => task_ids,
            "mode" => "wait_any",
            "timeout_ms" => 100
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert %AgentCore.Types.AgentToolResult{} = join_result
      assert join_result.details.status in ["timeout", "completed"]

      case join_result.details.status do
        "timeout" -> assert join_result.details.snapshot.mode == :wait_any
        "completed" -> assert join_result.details.mode == "wait_any"
      end
    end

    test "join defaults to wait_all when mode is invalid" do
      # Create a task
      result =
        Task.execute(
          "call_1",
          %{
            "description" => "Default mode test",
            "prompt" => "Test",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      join_result =
        Task.execute(
          "call_2",
          %{
            "action" => "join",
            "task_ids" => [result.details.task_id],
            "mode" => "invalid_mode",
            "timeout_ms" => 100
          },
          nil,
          nil,
          "/tmp",
          []
        )

      # Should default to wait_all
      assert %AgentCore.Types.AgentToolResult{} = join_result
      assert join_result.details.status in ["timeout", "completed"]

      case join_result.details.status do
        "timeout" -> assert join_result.details.snapshot.mode == :wait_all
        "completed" -> assert join_result.details.mode == "wait_all"
      end
    end
  end

  describe "execute/6 - join with unknown task" do
    test "join returns error when task_id doesn't exist" do
      result =
        Task.execute(
          "call_1",
          %{
            "action" => "join",
            "task_ids" => ["nonexistent_task_12345"]
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Unknown task_id: nonexistent_task_12345"} = result
    end

    test "join returns error when any task_id in list doesn't exist" do
      # Create one valid task
      create_result =
        Task.execute(
          "call_1",
          %{
            "description" => "Partial test",
            "prompt" => "Test",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          []
        )

      result =
        Task.execute(
          "call_2",
          %{
            "action" => "join",
            "task_ids" => [create_result.details.task_id, "nonexistent_task"]
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Unknown task_id: nonexistent_task"} = result
    end
  end

  describe "execute/6 - join with task missing run_id" do
    test "join returns error when task has no run_id" do
      # Create a task directly in TaskStore without a run_id
      task_id = TaskStore.new_task(%{description: "No run_id task"})

      result =
        Task.execute(
          "call_1",
          %{
            "action" => "join",
            "task_ids" => [task_id]
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Task " <> ^task_id <> " is missing a run_id"} = result
    end
  end

  describe "execute/6 - invalid input edge cases" do
    test "join handles null task_ids" do
      result =
        Task.execute(
          "call_1",
          %{
            "action" => "join",
            "task_ids" => nil
          },
          nil,
          nil,
          "/tmp",
          []
        )

      assert {:error, "task_ids is required for action=join"} = result
    end

    # timeout_ms edge-case tests removed: join should not time out.

    test "join handles empty string task_ids" do
      result =
        Task.execute(
          "call_1",
          %{
            "action" => "join",
            "task_ids" => [""]
          },
          nil,
          nil,
          "/tmp",
          []
        )

      # Empty string is still a valid string, so validation passes
      # But it will fail to find the task
      assert {:error, "Unknown task_id: "} = result
    end
  end
end
