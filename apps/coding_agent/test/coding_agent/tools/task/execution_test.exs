defmodule CodingAgent.Tools.Task.ExecutionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.BudgetTracker
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

      assert %LemonAgent.Types.AgentToolResult{} = result
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

      assert %LemonAgent.Types.AgentToolResult{} = result

      assert {:error, :not_found} =
               TaskProgressBindingStore.get_by_task_id(result.details.task_id)
    end

    test "fails immediately and terminalizes bookkeeping when the worker cannot start" do
      missing_supervisor = :missing_task_supervisor_for_launch_test

      assert {:error, "Background task supervisor is unavailable"} =
               Task.execute(
                 "tool_call_launch_failure",
                 %{
                   "description" => "Launch failure task",
                   "prompt" => "This worker must not run",
                   "async" => true
                 },
                 nil,
                 nil,
                 "/tmp",
                 parent_run_id: "run_parent_launch_failure",
                 session_key: "agent:default:telegram:default:dm:12345",
                 agent_id: "default",
                 task_supervisor: missing_supervisor
               )

      assert [{task_id, %{status: :error, error: :task_supervisor_unavailable} = record}] =
               TaskStore.list(:error)

      assert {:ok, %{status: :error, error: :task_supervisor_unavailable}} =
               RunGraph.get(record.run_id)

      assert {:error, :not_found} = TaskProgressBindingStore.get_by_task_id(task_id)
    end

    test "maps exhausted task capacity and releases all launch bookkeeping" do
      supervisor = start_supervised!({Elixir.Task.Supervisor, max_children: 1})

      {:ok, blocker} =
        LemonCore.TaskSupervisor.start_child(supervisor, fn ->
          receive do: (:release -> :ok)
        end)

      parent_run_id = RunGraph.new_run(%{type: :session})
      BudgetTracker.store_budget(parent_run_id, BudgetTracker.create_budget(max_children: 1))
      caller = self()
      on_update = fn result -> send(caller, {:capacity_update, result}) end

      assert {:error, "Background task capacity is exhausted"} =
               Task.execute(
                 "tool_call_capacity_failure",
                 %{
                   "description" => "Capacity failure task",
                   "prompt" => "This worker must not run",
                   "async" => true
                 },
                 nil,
                 on_update,
                 "/tmp",
                 parent_run_id: parent_run_id,
                 session_key: "agent:default:telegram:default:dm:12345",
                 agent_id: "default",
                 task_supervisor: supervisor
               )

      assert [{task_id, %{status: :error, error: :task_capacity_reached} = record}] =
               TaskStore.list(:error)

      assert {:ok, %{status: :error, error: :task_capacity_reached}} =
               RunGraph.get(record.run_id)

      assert {:error, :not_found} = TaskProgressBindingStore.get_by_task_id(task_id)

      assert %{active_children: 0, active_child_ids: [], completed_child_ids: [child_id]} =
               BudgetTracker.get_budget(parent_run_id)

      assert child_id == record.run_id

      assert_receive {:capacity_update,
                      %LemonAgent.Types.AgentToolResult{
                        is_error: true,
                        details: %{task_id: ^task_id, status: "error"},
                        content: [%LemonAi.Types.TextContent{text: "task_capacity_reached"}]
                      }}

      assert Elixir.Task.Supervisor.children(supervisor) == [blocker]
    end
  end
end
