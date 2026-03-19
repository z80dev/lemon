defmodule CodingAgent.Tools.Task.ExecutionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.RunGraph
  alias CodingAgent.TaskProgressBindingServer
  alias CodingAgent.TaskProgressBindingStore
  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task

  setup do
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

    try do
      TaskProgressBindingServer.clear(CodingAgent.TaskProgressBindingServer)
    catch
      _, _ -> :ok
    end

    :ok
  end

  describe "async task progress binding" do
    test "stores parent surface binding when async task launches" do
      result =
        Task.execute(
          "tool_call_123",
          %{
            "description" => "Binding test task",
            "prompt" => "Return hello",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          parent_run_id: "run_parent_123",
          session_key: "agent:default:telegram:default:dm:12345",
          agent_id: "default"
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert result.details.status == "queued"
      assert is_binary(result.details.task_id)
      assert is_binary(result.details.run_id)

      assert {:ok, binding} = TaskProgressBindingStore.get_by_task_id(result.details.task_id)
      assert binding.task_id == result.details.task_id
      assert binding.child_run_id == result.details.run_id
      assert binding.parent_run_id == "run_parent_123"
      assert binding.parent_session_key == "agent:default:telegram:default:dm:12345"
      assert binding.parent_agent_id == "default"
      assert binding.root_action_id == "tool_call_123"
      assert binding.surface == {:status_task, "tool_call_123"}
      assert binding.status == :running
    end

    test "does not store binding when parent surface metadata is unavailable" do
      result =
        Task.execute(
          nil,
          %{
            "description" => "No binding task",
            "prompt" => "Return hello",
            "async" => true
          },
          nil,
          nil,
          "/tmp",
          parent_run_id: "run_parent_123",
          session_key: "agent:default:telegram:default:dm:12345",
          agent_id: "default",
          root_action_id: nil,
          surface: nil
        )

      assert %AgentCore.Types.AgentToolResult{} = result
      assert {:error, :not_found} = TaskProgressBindingStore.get_by_task_id(result.details.task_id)
    end
  end
end
