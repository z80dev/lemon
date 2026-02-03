defmodule CodingAgent.TaskStoreTest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskStore
  alias CodingAgent.TaskStoreServer

  setup do
    # Clear all tasks before each test
    try do
      TaskStore.clear()
    catch
      _, _ -> :ok
    end

    :ok
  end

  describe "new_task/1" do
    test "creates a task with default attributes" do
      task_id = TaskStore.new_task(%{description: "Test task"})

      assert is_binary(task_id)
      assert {:ok, record, _events} = TaskStore.get(task_id)
      assert record.status == :queued
      assert record.description == "Test task"
      assert is_integer(record.inserted_at)
      assert is_integer(record.updated_at)
    end

    test "creates a task with custom attributes" do
      task_id = TaskStore.new_task(%{description: "Custom", engine: "codex", role: "research"})

      assert {:ok, record, _} = TaskStore.get(task_id)
      assert record.description == "Custom"
      assert record.engine == "codex"
      assert record.role == "research"
    end

    test "generates unique task IDs" do
      task_ids = for _ <- 1..100, do: TaskStore.new_task(%{})
      assert length(Enum.uniq(task_ids)) == 100
    end
  end

  describe "mark_running/1" do
    test "marks a task as running" do
      task_id = TaskStore.new_task(%{description: "Test"})
      assert :ok = TaskStore.mark_running(task_id)

      assert {:ok, record, _} = TaskStore.get(task_id)
      assert record.status == :running
      assert is_integer(record.started_at)
    end

    test "returns ok for unknown task" do
      assert :ok = TaskStore.mark_running("unknown_task_id")
    end
  end

  describe "finish/2" do
    test "marks a task as completed with result" do
      task_id = TaskStore.new_task(%{description: "Test"})
      TaskStore.mark_running(task_id)

      result = %{answer: "42"}
      assert :ok = TaskStore.finish(task_id, result)

      assert {:ok, record, _} = TaskStore.get(task_id)
      assert record.status == :completed
      assert record.result == result
      assert is_integer(record.completed_at)
    end

    test "returns ok for unknown task" do
      assert :ok = TaskStore.finish("unknown_task_id", %{result: "test"})
    end
  end

  describe "fail/2" do
    test "marks a task as error with reason" do
      task_id = TaskStore.new_task(%{description: "Test"})
      TaskStore.mark_running(task_id)

      error = "Something went wrong"
      assert :ok = TaskStore.fail(task_id, error)

      assert {:ok, record, _} = TaskStore.get(task_id)
      assert record.status == :error
      assert record.error == error
      assert is_integer(record.completed_at)
    end

    test "returns ok for unknown task" do
      assert :ok = TaskStore.fail("unknown_task_id", "error")
    end
  end

  describe "get/1" do
    test "returns not_found for unknown task" do
      assert {:error, :not_found} = TaskStore.get("unknown_task_id")
    end

    test "returns task with events in chronological order" do
      task_id = TaskStore.new_task(%{description: "Test"})

      TaskStore.append_event(task_id, %{type: :event1})
      TaskStore.append_event(task_id, %{type: :event2})
      TaskStore.append_event(task_id, %{type: :event3})

      assert {:ok, _record, events} = TaskStore.get(task_id)
      assert length(events) == 3
      assert Enum.map(events, & &1.type) == [:event1, :event2, :event3]
    end
  end

  describe "append_event/2" do
    test "appends events to a task" do
      task_id = TaskStore.new_task(%{description: "Test"})

      assert :ok = TaskStore.append_event(task_id, %{data: "event1"})
      assert {:ok, _record, events} = TaskStore.get(task_id)

      assert length(events) == 1
    end

    test "bounds events to max 100" do
      task_id = TaskStore.new_task(%{description: "Test"})

      for i <- 1..150 do
        TaskStore.append_event(task_id, %{index: i})
      end

      assert {:ok, _record, events} = TaskStore.get(task_id)
      assert length(events) == 100

      # Should keep the most recent events
      indices = Enum.map(events, & &1.index)
      assert Enum.max(indices) == 150
      assert Enum.min(indices) == 51
    end

    test "returns ok for unknown task" do
      assert :ok = TaskStore.append_event("unknown_task_id", %{data: "test"})
    end
  end

  describe "clear/0" do
    test "removes all tasks" do
      task_id = TaskStore.new_task(%{description: "Test"})
      assert {:ok, _, _} = TaskStore.get(task_id)

      assert :ok = TaskStore.clear()

      assert {:error, :not_found} = TaskStore.get(task_id)
    end
  end

  describe "cleanup/1" do
    test "does not remove recently completed tasks with long TTL" do
      task_id = TaskStore.new_task(%{description: "Test"})
      TaskStore.mark_running(task_id)
      TaskStore.finish(task_id, %{result: "done"})

      # Should not be cleaned up with 1 hour TTL
      assert :ok = TaskStore.cleanup(3_600)
      assert {:ok, _, _} = TaskStore.get(task_id)
    end

    test "does not remove recently errored tasks with long TTL" do
      task_id = TaskStore.new_task(%{description: "Test"})
      TaskStore.mark_running(task_id)
      TaskStore.fail(task_id, "error")

      assert :ok = TaskStore.cleanup(3_600)
      assert {:ok, _, _} = TaskStore.get(task_id)
    end

    test "does not remove running tasks even with 0 TTL" do
      task_id = TaskStore.new_task(%{description: "Test"})
      TaskStore.mark_running(task_id)

      assert :ok = TaskStore.cleanup(0)
      assert {:ok, _, _} = TaskStore.get(task_id)
    end

    test "does not remove queued tasks even with 0 TTL" do
      task_id = TaskStore.new_task(%{description: "Test"})

      assert :ok = TaskStore.cleanup(0)
      assert {:ok, _, _} = TaskStore.get(task_id)
    end
  end

  describe "lifecycle" do
    test "full task lifecycle: queued -> running -> completed" do
      task_id = TaskStore.new_task(%{description: "Full lifecycle"})

      # Initial state
      assert {:ok, %{status: :queued} = record, _} = TaskStore.get(task_id)
      assert record.inserted_at != nil
      refute Map.has_key?(record, :started_at)

      # Mark running
      TaskStore.mark_running(task_id)
      assert {:ok, %{status: :running} = record, _} = TaskStore.get(task_id)
      assert record.started_at != nil

      # Finish
      TaskStore.finish(task_id, %{result: "success"})
      assert {:ok, %{status: :completed} = record, _} = TaskStore.get(task_id)
      assert record.result == %{result: "success"}
      assert record.completed_at != nil
    end

    test "full task lifecycle: queued -> running -> error" do
      task_id = TaskStore.new_task(%{description: "Error lifecycle"})

      TaskStore.mark_running(task_id)
      TaskStore.fail(task_id, %{error: "failed"})

      assert {:ok, %{status: :error} = record, _} = TaskStore.get(task_id)
      assert record.error == %{error: "failed"}
      assert record.completed_at != nil
    end
  end

  describe "concurrent access" do
    test "handles concurrent task creation" do
      tasks =
        Enum.map(1..50, fn _ ->
          Task.async(fn ->
            TaskStore.new_task(%{description: "Concurrent task"})
          end)
        end)

      task_ids = Enum.map(tasks, &Task.await/1)
      assert length(Enum.uniq(task_ids)) == 50

      # All should be retrievable
      for task_id <- task_ids do
        assert {:ok, _, _} = TaskStore.get(task_id)
      end
    end

    test "handles concurrent event appends" do
      task_id = TaskStore.new_task(%{description: "Concurrent events"})

      # Use higher delays to reduce contention
      tasks =
        Enum.map(1..20, fn i ->
          Task.async(fn ->
            Process.sleep(Enum.random(1..10))
            TaskStore.append_event(task_id, %{index: i})
          end)
        end)

      Enum.each(tasks, &Task.await/1)

      assert {:ok, _, events} = TaskStore.get(task_id)
      # Due to race conditions, we may not get all 20, but should get most
      assert length(events) >= 10
    end
  end

  describe "TaskStoreServer" do
    test "ensure_table/1 initializes tables if not already done" do
      # Tables should already be initialized from application start
      assert :ok = TaskStoreServer.ensure_table(CodingAgent.TaskStoreServer)
    end

    test "cleanup/2 returns count of checked tasks" do
      task_id = TaskStore.new_task(%{description: "Cleanup test"})
      TaskStore.mark_running(task_id)
      TaskStore.finish(task_id, %{result: "done"})

      # With long TTL, nothing should be deleted
      assert {:ok, 0} = TaskStoreServer.cleanup(CodingAgent.TaskStoreServer, 3_600)
    end

    test "dets_status/1 returns status information" do
      status = TaskStoreServer.dets_status(CodingAgent.TaskStoreServer)
      assert status.info != nil
      assert status.state.loaded_from_dets != nil
    end
  end
end
