defmodule CodingAgent.Tools.TaskAsyncTest do
  alias Elixir.CodingAgent, as: CodingAgent
  use ExUnit.Case, async: false

  alias Elixir.CodingAgent.Tools.Task
  alias Elixir.CodingAgent.TaskStore
  alias Elixir.CodingAgent.RunGraph
  alias CodingAgent.Messages
  alias CodingAgent.Messages.CustomMessage
  alias LemonCore.RunRequest

  defmodule TaskAsyncStubRunOrchestrator do
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

  defmodule TaskAsyncSessionSpy do
    def handle_async_followup(pid, message) do
      send(
        pid,
        {:session_async_followup, CodingAgent.Session.State.build_async_followup_message(message)}
      )

      :ok
    end

    def get_state(_pid) do
      %{is_streaming: true}
    end
  end

  defmodule TaskAsyncIdleSessionSpy do
    def handle_async_followup(pid, message) do
      send(
        pid,
        {:session_async_followup, CodingAgent.Session.State.build_async_followup_message(message)}
      )

      :ok
    end

    def get_state(_pid) do
      %{is_streaming: false}
    end
  end

  setup do
    previous_async_followups = Application.get_env(:coding_agent, :async_followups)

    on_exit(fn ->
      Application.put_env(:coding_agent, :async_followups, previous_async_followups)
    end)

    start_supervised!(__MODULE__.TaskAsyncStubRunOrchestrator)
    __MODULE__.TaskAsyncStubRunOrchestrator.configure(self())

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
    test "queue_mode followup uses the live session when session pid is available" do
      result =
        Task.execute(
          "call_live_followup",
          %{
            "description" => "Live followup task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
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
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"

      assert_receive {:session_async_followup, %CustomMessage{} = message}, 1_000
      assert message.custom_type == "async_followup"
      assert message.content =~ "[task #{result.details.task_id}]"
      assert message.content =~ "Live followup task"
      assert message.content =~ "task output"
      assert message.details.source == :task
      assert message.details.task_id == result.details.task_id
      assert message.details.run_id == result.details.run_id
      assert message.details.delivery == :followup

      [llm_message] = Messages.to_llm([message])
      assert %Ai.Types.UserMessage{} = llm_message
      assert llm_message.content =~ "[SYSTEM-DELIVERED ASYNC COMPLETION - NOT A USER MESSAGE]"
      assert llm_message.content =~ "Source: task (ID: #{result.details.task_id})"
      assert llm_message.content =~ "Run: #{result.details.run_id}"
      assert llm_message.content =~ "Delivery: followup"
      assert llm_message.content =~ message.content

      refute_receive {:router_submit, %RunRequest{}, _}, 150
    end

    test "queue_mode steer uses the live session when the parent is streaming" do
      result =
        Task.execute(
          "call_live_steer",
          %{
            "description" => "Live steer task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "steer"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "steer output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result

      assert_receive {:session_async_followup, %CustomMessage{} = message}, 1_000
      assert message.details.delivery == :steer
      assert message.content =~ "steer output"
      refute_receive {:router_submit, %RunRequest{}, _}, 150
    end

    test "queue_mode followup falls back to router when session pid is unavailable" do
      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}

      parent_cwd = "/tmp/task_async_parent"

      result =
        Task.execute(
          "call_router_followup",
          %{
            "description" => "Router followup task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          parent_cwd,
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "router output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: dead_pid,
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"

      assert_receive {:router_submit, %RunRequest{queue_mode: :followup} = followup, 1}, 1_000
      assert followup.session_key == "agent:main:main"
      assert followup.agent_id == "main"
      assert followup.cwd == parent_cwd
      assert followup.prompt =~ "Router followup task"
      assert followup.prompt =~ "router output"

      assert followup.meta["async_followups"] == [
               %{
                 source: :task,
                 task_id: result.details.task_id,
                 run_id: result.details.run_id,
                 delivery: :followup
               }
             ]
    end

    test "queue_mode followup uses the live session even when the parent is idle" do
      result =
        Task.execute(
          "call_idle_followup",
          %{
            "description" => "Idle followup task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          "/tmp/task_async_idle_parent",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "idle output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncIdleSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"

      assert_receive {:session_async_followup, %CustomMessage{} = message}, 1_000
      assert message.details.delivery == :followup
      assert message.content =~ "Idle followup task"
      assert message.content =~ "idle output"
      refute_receive {:router_submit, %RunRequest{}, _}, 150
    end

    test "queue_mode steer_backlog still uses router when a streaming parent session exists" do
      result =
        Task.execute(
          "call_router_backlog",
          %{
            "description" => "Backlog routing task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "steer_backlog"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "override output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"

      refute_receive {:session_async_followup, _message}, 150

      assert_receive {:router_submit, %RunRequest{queue_mode: :steer_backlog} = followup, 1},
                     1_000

      assert followup.session_key == "agent:main:main"
      assert followup.agent_id == "main"
      assert followup.meta.task_id == result.details.task_id
      assert followup.meta.run_id == result.details.run_id
      assert followup.meta.task_auto_followup == true

      assert followup.meta["async_followups"] == [
               %{
                 source: :task,
                 task_id: result.details.task_id,
                 run_id: result.details.run_id,
                 delivery: :steer_backlog
               }
             ]
    end

    test "queue_mode interrupt still uses router when a streaming parent session exists" do
      result =
        Task.execute(
          "call_router_interrupt",
          %{
            "description" => "Interrupt routing task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "interrupt",
            "session_key" => "agent:review:main",
            "agent_id" => "review",
            "meta" => %{"origin" => "task_async_test"}
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "interrupt output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      refute_receive {:session_async_followup, _message}, 150
      assert_receive {:router_submit, %RunRequest{queue_mode: :interrupt} = followup, 1}, 1_000
      assert followup.session_key == "agent:review:main"
      assert followup.agent_id == "review"
      assert followup.meta["origin"] == "task_async_test"

      assert followup.meta["async_followups"] == [
               %{
                 source: :task,
                 task_id: result.details.task_id,
                 run_id: result.details.run_id,
                 delivery: :interrupt
               }
             ]
    end

    test "omitted queue_mode uses the configured async followup default" do
      Application.put_env(:coding_agent, :async_followups, default_queue_mode: :interrupt)

      result =
        Task.execute(
          "call_config_default",
          %{
            "description" => "Config default task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "config output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      refute_receive {:session_async_followup, _message}, 150
      assert_receive {:router_submit, %RunRequest{queue_mode: :interrupt} = followup, 1}, 1_000
      assert followup.meta.task_id == result.details.task_id
    end

    test "explicit queue_mode overrides the configured async followup default" do
      Application.put_env(:coding_agent, :async_followups, default_queue_mode: :interrupt)

      result =
        Task.execute(
          "call_config_override",
          %{
            "description" => "Config override task",
            "prompt" => "Return completion",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "override output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert_receive {:session_async_followup, %CustomMessage{} = message}, 1_000
      assert message.details.delivery == :followup
      refute_receive {:router_submit, %RunRequest{}, _}, 150
      assert result.details.status == "queued"
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
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      refute_receive {:session_async_followup, _message}, 200
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

  # ============================================================================
  # Follow-up Text Formatting Tests
  # ============================================================================

  describe "task_auto_followup_text formatting" do
    test "formats successful completion with answer" do
      result =
        Task.execute(
          "call_fmt_success",
          %{
            "description" => "Build widget",
            "prompt" => "Build it",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "Widget built successfully"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      task_id = result.details.task_id
      run_id = result.details.run_id

      assert_receive {:session_async_followup, %CustomMessage{} = message}, 1_000
      assert message.content =~ "[task #{task_id}]"
      assert message.content =~ "Build widget"
      assert message.content =~ "run="
      assert message.content =~ "completed."
      assert message.content =~ "Widget built successfully"
    end

    test "formats failed task with error" do
      result =
        Task.execute(
          "call_fmt_fail",
          %{
            "description" => "Broken task",
            "prompt" => "Do broken thing",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            {:error, "connection refused"}
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      task_id = result.details.task_id

      assert_receive {:session_async_followup, %CustomMessage{} = message}, 1_000
      assert message.content =~ "[task #{task_id}]"
      assert message.content =~ "Broken task"
      assert message.content =~ "failed:"
      assert message.content =~ "connection refused"
    end

    test "formats completion with empty answer" do
      result =
        Task.execute(
          "call_fmt_empty",
          %{
            "description" => "Silent task",
            "prompt" => "Do silent thing",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: ""}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      task_id = result.details.task_id

      assert_receive {:session_async_followup, %CustomMessage{} = message}, 1_000
      assert message.content =~ "[task #{task_id}]"
      assert message.content =~ "completed."
      # Should NOT contain trailing content after "completed."
      refute message.content =~ "completed.\n\n\n"
    end

    test "formats failure with partial output" do
      result =
        Task.execute(
          "call_fmt_partial",
          %{
            "description" => "Partial task",
            "prompt" => "Partially complete",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "Got halfway done"}],
              details: %{status: "error", error: "timeout"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      task_id = result.details.task_id

      assert_receive {:session_async_followup, %CustomMessage{} = message}, 1_000
      assert message.content =~ "[task #{task_id}]"
      assert message.content =~ "failed:"
      assert message.content =~ "timeout"
      assert message.content =~ "Partial output:"
      assert message.content =~ "Got halfway done"
    end
  end

  # ============================================================================
  # Error Resilience Tests
  # ============================================================================

  describe "follow-up error resilience" do
    defmodule CrashingSession do
      def handle_async_followup(_pid, _message) do
        raise "session exploded"
      end
    end

    defmodule NoFollowUpSession do
      # This module intentionally does NOT export handle_async_followup/2
    end

    test "handles session crash during follow_up gracefully" do
      result =
        Task.execute(
          "call_crash",
          %{
            "description" => "Crash resilience test",
            "prompt" => "Test crash",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "done"}],
              details: %{status: "completed"}
            }
          end,
          session_module: CrashingSession,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"

      # Session crashes, so it should fall back to router
      assert_receive {:router_submit, %RunRequest{queue_mode: :followup}, _}, 1_000
    end

    test "falls back to router when session module lacks handle_async_followup/2" do
      result =
        Task.execute(
          "call_no_func",
          %{
            "description" => "No async followup func test",
            "prompt" => "Test missing func",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: NoFollowUpSession,
          session_pid: self(),
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"

      # Session module doesn't have handle_async_followup/2, so it should route via router
      assert_receive {:router_submit, %RunRequest{queue_mode: :followup}, _}, 1_000
    end

    test "falls back to router when session_pid is nil" do
      result =
        Task.execute(
          "call_nil_pid",
          %{
            "description" => "Nil pid test",
            "prompt" => "Test nil",
            "async" => true,
            "auto_followup" => true,
            "queue_mode" => "followup"
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "output"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: nil,
          session_key: "agent:main:main",
          agent_id: "main",
          run_orchestrator: __MODULE__.TaskAsyncStubRunOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result

      # nil session_pid should fall back to router
      assert_receive {:router_submit, %RunRequest{queue_mode: :followup}, _}, 1_000
    end
  end

  # ============================================================================
  # Router Fallback for Unknown Agent ID
  # ============================================================================

  describe "router fallback for unknown agent_id" do
    defmodule UnknownAgentOrchestrator do
      use Agent

      def start_link(_opts) do
        Agent.start_link(fn -> %{owner: nil, submissions: []} end, name: __MODULE__)
      end

      def configure(owner) when is_pid(owner) do
        Agent.update(__MODULE__, fn _ -> %{owner: owner, submissions: []} end)
      end

      def submit(%RunRequest{agent_id: "unknown_agent"} = request) do
        Agent.get_and_update(__MODULE__, fn state ->
          new_state = %{state | submissions: state.submissions ++ [{:rejected, request}]}

          if is_pid(state.owner) do
            send(state.owner, {:router_rejected, request})
          end

          {{:error, {:unknown_agent_id, "unknown_agent"}}, new_state}
        end)
      end

      def submit(%RunRequest{agent_id: "default"} = request) do
        Agent.get_and_update(__MODULE__, fn state ->
          new_state = %{state | submissions: state.submissions ++ [{:fallback, request}]}

          if is_pid(state.owner) do
            send(state.owner, {:router_fallback, request})
          end

          {{:ok, "fallback_run_1"}, new_state}
        end)
      end

      def submit(%RunRequest{} = request) do
        Agent.get_and_update(__MODULE__, fn state ->
          new_state = %{state | submissions: state.submissions ++ [{:ok, request}]}

          if is_pid(state.owner) do
            send(state.owner, {:router_submit, request})
          end

          {{:ok, "run_1"}, new_state}
        end)
      end
    end

    test "falls back to default agent_id when original agent_id is unknown" do
      start_supervised!(UnknownAgentOrchestrator)
      UnknownAgentOrchestrator.configure(self())

      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}

      result =
        Task.execute(
          "call_unknown_agent",
          %{
            "description" => "Unknown agent fallback",
            "prompt" => "Test fallback",
            "async" => true,
            "auto_followup" => true
          },
          nil,
          nil,
          "/tmp",
          run_override: fn _on_update, _signal ->
            %AgentCore.Types.AgentToolResult{
              content: [%Ai.Types.TextContent{text: "done"}],
              details: %{status: "completed"}
            }
          end,
          session_module: __MODULE__.TaskAsyncSessionSpy,
          session_pid: dead_pid,
          session_key: "agent:unknown_agent:main",
          agent_id: "unknown_agent",
          run_orchestrator: UnknownAgentOrchestrator
        )

      assert %AgentCore.Types.AgentToolResult{} = result

      # First attempt with "unknown_agent" should be rejected
      assert_receive {:router_rejected, %RunRequest{agent_id: "unknown_agent"}}, 1_000

      # Fallback to "default" should succeed
      assert_receive {:router_fallback, %RunRequest{agent_id: "default"}}, 1_000
    end
  end
end
