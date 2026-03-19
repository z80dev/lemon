defmodule CodingAgent.TaskProgressBindingStoreTest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskProgressBindingStore

  setup do
    TaskProgressBindingStore.list_all()
    |> Enum.each(fn binding ->
      TaskProgressBindingStore.delete_by_child_run_id(binding.child_run_id)
    end)

    :ok
  end

  describe "replacement semantics" do
    test "rebinding the same task_id replaces the old child_run_id" do
      original = binding_attrs(%{task_id: "task-rebind", child_run_id: "child-old"})
      replacement = binding_attrs(%{task_id: "task-rebind", child_run_id: "child-new"})

      :ok = TaskProgressBindingStore.new_binding(original)
      :ok = TaskProgressBindingStore.new_binding(replacement)

      assert {:error, :not_found} = TaskProgressBindingStore.get_by_child_run_id("child-old")
      assert {:ok, binding} = TaskProgressBindingStore.get_by_task_id("task-rebind")
      assert binding.child_run_id == "child-new"
      assert Enum.count(TaskProgressBindingStore.list_all(), &(&1.task_id == "task-rebind")) == 1
    end

    test "rebinding the same child_run_id updates the task index cleanly" do
      original = binding_attrs(%{task_id: "task-old", child_run_id: "child-stable"})
      replacement = binding_attrs(%{task_id: "task-new", child_run_id: "child-stable"})

      :ok = TaskProgressBindingStore.new_binding(original)
      :ok = TaskProgressBindingStore.new_binding(replacement)

      assert {:error, :not_found} = TaskProgressBindingStore.get_by_task_id("task-old")
      assert {:ok, binding} = TaskProgressBindingStore.get_by_task_id("task-new")
      assert binding.child_run_id == "child-stable"

      assert Enum.count(TaskProgressBindingStore.list_all(), &(&1.child_run_id == "child-stable")) ==
               1
    end
  end

  describe "server recovery" do
    test "restarts the binding server when the child is missing from the supervisor" do
      original_pid = Process.whereis(CodingAgent.TaskProgressBindingServer)
      assert is_pid(original_pid)

      assert :ok =
               Supervisor.terminate_child(
                 CodingAgent.Supervisor,
                 CodingAgent.TaskProgressBindingServer
               )

      assert :ok =
               Supervisor.delete_child(
                 CodingAgent.Supervisor,
                 CodingAgent.TaskProgressBindingServer
               )

      assert Process.whereis(CodingAgent.TaskProgressBindingServer) == nil

      assert [] = TaskProgressBindingStore.list_all()

      restarted_pid = Process.whereis(CodingAgent.TaskProgressBindingServer)
      assert is_pid(restarted_pid)
      refute restarted_pid == original_pid
    end
  end

  defp binding_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        task_id: "task-123",
        child_run_id: "child-run-123",
        parent_run_id: "parent-run-123",
        parent_session_key: "session-123",
        parent_agent_id: "agent-123",
        root_action_id: "root-action-123",
        surface: {:status_task, "root-action-123"},
        inserted_at_ms: System.system_time(:millisecond),
        status: :running
      },
      overrides
    )
  end

  describe "new_binding/1 and lookups" do
    test "stores a binding and looks it up by task_id and child_run_id" do
      attrs = binding_attrs()

      assert :ok = TaskProgressBindingStore.new_binding(attrs)
      assert {:ok, binding} = TaskProgressBindingStore.get_by_task_id(attrs.task_id)
      assert {:ok, ^binding} = TaskProgressBindingStore.get_by_child_run_id(attrs.child_run_id)

      assert binding.task_id == attrs.task_id
      assert binding.child_run_id == attrs.child_run_id
      assert binding.parent_run_id == attrs.parent_run_id
      assert binding.parent_session_key == attrs.parent_session_key
      assert binding.parent_agent_id == attrs.parent_agent_id
      assert binding.root_action_id == attrs.root_action_id
      assert binding.surface == attrs.surface
      assert binding.status == :running
      assert is_integer(binding.inserted_at_ms)
    end

    test "returns not_found for missing keys" do
      assert {:error, :not_found} = TaskProgressBindingStore.get_by_task_id("missing-task")
      assert {:error, :not_found} = TaskProgressBindingStore.get_by_child_run_id("missing-child")
    end

    test "applies defaults for inserted_at_ms and status" do
      attrs =
        binding_attrs()
        |> Map.delete(:inserted_at_ms)
        |> Map.delete(:status)

      assert :ok = TaskProgressBindingStore.new_binding(attrs)
      assert {:ok, binding} = TaskProgressBindingStore.get_by_child_run_id(attrs.child_run_id)
      assert is_integer(binding.inserted_at_ms)
      assert binding.status == :running
    end

    test "accepts the generic :status surface" do
      attrs = binding_attrs(%{surface: :status})

      assert :ok = TaskProgressBindingStore.new_binding(attrs)
      assert {:ok, binding} = TaskProgressBindingStore.get_by_child_run_id(attrs.child_run_id)
      assert binding.surface == :status
    end

    test "raises for missing required fields" do
      attrs = binding_attrs() |> Map.delete(:root_action_id)

      assert_raise ArgumentError,
                   ~r/missing required task progress binding field :root_action_id/,
                   fn ->
                     TaskProgressBindingStore.new_binding(attrs)
                   end
    end

    test "raises for invalid required field types" do
      attrs = binding_attrs(%{task_id: 123})

      assert_raise ArgumentError, ~r/invalid task progress binding field :task_id/, fn ->
        TaskProgressBindingStore.new_binding(attrs)
      end
    end

    test "raises for invalid surface shape" do
      attrs = binding_attrs(%{surface: %{bad: :surface}})

      assert_raise ArgumentError, ~r/invalid task progress binding field :surface/, fn ->
        TaskProgressBindingStore.new_binding(attrs)
      end
    end

    test "raises for invalid inserted_at_ms" do
      attrs = binding_attrs(%{inserted_at_ms: "not-an-int"})

      assert_raise ArgumentError, ~r/invalid task progress binding field :inserted_at_ms/, fn ->
        TaskProgressBindingStore.new_binding(attrs)
      end
    end

    test "raises for invalid status" do
      attrs = binding_attrs(%{status: :paused})

      assert_raise ArgumentError, ~r/invalid task progress binding field :status/, fn ->
        TaskProgressBindingStore.new_binding(attrs)
      end
    end
  end

  describe "delete_by_child_run_id/1" do
    test "deletes a binding and removes both lookup paths" do
      attrs = binding_attrs()
      :ok = TaskProgressBindingStore.new_binding(attrs)

      assert :ok = TaskProgressBindingStore.delete_by_child_run_id(attrs.child_run_id)
      assert {:error, :not_found} = TaskProgressBindingStore.get_by_task_id(attrs.task_id)

      assert {:error, :not_found} =
               TaskProgressBindingStore.get_by_child_run_id(attrs.child_run_id)
    end
  end

  describe "mark_completed/1" do
    test "overwrites binding status in place" do
      attrs = binding_attrs(%{status: :running})
      :ok = TaskProgressBindingStore.new_binding(attrs)

      assert :ok = TaskProgressBindingStore.mark_completed(attrs.child_run_id)
      assert {:ok, binding} = TaskProgressBindingStore.get_by_child_run_id(attrs.child_run_id)
      assert binding.status == :completed
      assert is_integer(binding.completed_at_ms)
      assert binding.task_id == attrs.task_id
    end

    test "returns ok for missing child run id" do
      assert :ok = TaskProgressBindingStore.mark_completed("missing-child")
    end
  end

  describe "cleanup_expired/1" do
    test "removes stale bindings by ttl and keeps fresh ones" do
      old_binding =
        binding_attrs(%{
          task_id: "task-old",
          child_run_id: "child-old",
          inserted_at_ms: System.system_time(:millisecond) - 20_000,
          status: :completed,
          completed_at_ms: System.system_time(:millisecond) - 10_000
        })

      fresh_binding =
        binding_attrs(%{
          task_id: "task-fresh",
          child_run_id: "child-fresh",
          inserted_at_ms: System.system_time(:millisecond)
        })

      :ok = TaskProgressBindingStore.new_binding(old_binding)
      :ok = TaskProgressBindingStore.new_binding(fresh_binding)

      assert {:ok, 1} = TaskProgressBindingStore.cleanup_expired(5)

      assert {:error, :not_found} =
               TaskProgressBindingStore.get_by_child_run_id(old_binding.child_run_id)

      assert {:error, :not_found} = TaskProgressBindingStore.get_by_task_id(old_binding.task_id)

      assert {:ok, _binding} =
               TaskProgressBindingStore.get_by_child_run_id(fresh_binding.child_run_id)
    end

    test "does not remove old running bindings" do
      running_binding =
        binding_attrs(%{
          task_id: "task-running",
          child_run_id: "child-running",
          inserted_at_ms: System.system_time(:millisecond) - 60_000,
          status: :running
        })

      :ok = TaskProgressBindingStore.new_binding(running_binding)

      assert {:ok, 0} = TaskProgressBindingStore.cleanup_expired(5)

      assert {:ok, binding} =
               TaskProgressBindingStore.get_by_child_run_id(running_binding.child_run_id)

      assert binding.status == :running
    end

    test "completed bindings age out from completion time, not insertion time" do
      binding =
        binding_attrs(%{
          task_id: "task-complete-age",
          child_run_id: "child-complete-age",
          inserted_at_ms: System.system_time(:millisecond) - 60_000,
          status: :running
        })

      :ok = TaskProgressBindingStore.new_binding(binding)
      :ok = TaskProgressBindingStore.mark_completed(binding.child_run_id)

      assert {:ok, 0} = TaskProgressBindingStore.cleanup_expired(5)

      assert {:ok, completed_binding} =
               TaskProgressBindingStore.get_by_child_run_id(binding.child_run_id)

      assert completed_binding.status == :completed

      old_completed_binding =
        Map.merge(completed_binding, %{completed_at_ms: System.system_time(:millisecond) - 10_000})

      :ok = TaskProgressBindingStore.new_binding(old_completed_binding)

      assert {:ok, 1} = TaskProgressBindingStore.cleanup_expired(5)

      assert {:error, :not_found} =
               TaskProgressBindingStore.get_by_child_run_id(binding.child_run_id)
    end
  end

  describe "delete_by_child_run_id/1 missing ids" do
    test "returns ok for missing child run id" do
      assert :ok = TaskProgressBindingStore.delete_by_child_run_id("missing-child")
    end
  end

  describe "server restart behavior" do
    test "transient bindings are cleared across server restart and api remains usable" do
      attrs = binding_attrs(%{task_id: "task-restart", child_run_id: "child-restart"})
      :ok = TaskProgressBindingStore.new_binding(attrs)

      old_pid = Process.whereis(CodingAgent.TaskProgressBindingServer)
      ref = Process.monitor(old_pid)
      Process.exit(old_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^old_pid, _reason}, 1_000

      new_pid = wait_for_restarted_binding_server(old_pid)
      assert is_pid(new_pid)

      assert {:error, :not_found} =
               TaskProgressBindingStore.get_by_child_run_id(attrs.child_run_id)

      replacement =
        binding_attrs(%{task_id: "task-after-restart", child_run_id: "child-after-restart"})

      assert :ok = TaskProgressBindingStore.new_binding(replacement)

      assert {:ok, binding} =
               TaskProgressBindingStore.get_by_child_run_id(replacement.child_run_id)

      assert binding.task_id == replacement.task_id
    end
  end

  defp wait_for_restarted_binding_server(old_pid, attempts \\ 40)

  defp wait_for_restarted_binding_server(_old_pid, attempts) when attempts <= 0 do
    flunk("timed out waiting for TaskProgressBindingServer to restart")
  end

  defp wait_for_restarted_binding_server(old_pid, attempts) do
    case Process.whereis(CodingAgent.TaskProgressBindingServer) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(25)
        wait_for_restarted_binding_server(old_pid, attempts - 1)
    end
  end
end
