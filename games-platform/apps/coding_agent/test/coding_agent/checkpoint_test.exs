defmodule CodingAgent.CheckpointTest do
  @moduledoc """
  Tests for the Checkpoint module.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Checkpoint
  alias CodingAgent.Tools.TodoStore

  describe "create/2 and resume/1" do
    test "creates and resumes a checkpoint" do
      session_id = unique_session("create-resume")

      on_exit(fn ->
        Checkpoint.delete_all(session_id)
        TodoStore.put(session_id, [])
      end)

      # Create some todos
      TodoStore.put(session_id, [
        %{id: "1", content: "Task 1", status: :completed, dependencies: [], priority: :high},
        %{id: "2", content: "Task 2", status: :in_progress, dependencies: [], priority: :medium}
      ])

      # Create checkpoint
      {:ok, checkpoint} =
        Checkpoint.create(session_id,
          context: %{step: 5},
          metadata: %{tag: "test"}
        )

      assert is_binary(checkpoint.id)
      assert checkpoint.session_id == session_id
      assert checkpoint.context.step == 5
      assert checkpoint.metadata.tag == "test"
      assert length(checkpoint.todos) == 2

      # Clear todos
      TodoStore.put(session_id, [])
      assert TodoStore.get(session_id) == []

      # Resume from checkpoint
      {:ok, state} = Checkpoint.resume(checkpoint.id)

      assert state.session_id == session_id
      assert state.context.step == 5
      assert state.resumed_from == checkpoint.id

      # Todos should be restored
      restored_todos = TodoStore.get(session_id)
      assert length(restored_todos) == 2
    end

    test "returns error for non-existent checkpoint" do
      assert {:error, :not_found} = Checkpoint.resume("chk_nonexistent")
    end
  end

  describe "list/1" do
    test "returns checkpoints sorted by timestamp" do
      session_id = unique_session("list-sorted")
      on_exit(fn -> Checkpoint.delete_all(session_id) end)

      # Create multiple checkpoints
      {:ok, _cp1} = Checkpoint.create(session_id, metadata: %{order: 1})
      :timer.sleep(10)
      # Ensure different timestamps
      {:ok, _cp2} = Checkpoint.create(session_id, metadata: %{order: 2})
      :timer.sleep(10)
      {:ok, _cp3} = Checkpoint.create(session_id, metadata: %{order: 3})

      checkpoints = Checkpoint.list(session_id)

      assert length(checkpoints) == 3
      # Should be sorted newest first
      assert hd(checkpoints).metadata.order == 3
      assert List.last(checkpoints).metadata.order == 1
    end

    test "returns empty list for session with no checkpoints" do
      assert Checkpoint.list(unique_session("no-checkpoints")) == []
    end

    test "only returns checkpoints for specified session" do
      session_a = unique_session("session-a")
      session_b = unique_session("session-b")

      on_exit(fn ->
        Checkpoint.delete_all(session_a)
        Checkpoint.delete_all(session_b)
      end)

      {:ok, _} = Checkpoint.create(session_a, metadata: %{session: "a"})
      {:ok, _} = Checkpoint.create(session_b, metadata: %{session: "b"})

      a_checkpoints = Checkpoint.list(session_a)
      assert length(a_checkpoints) == 1
      assert hd(a_checkpoints).metadata.session == "a"
    end
  end

  describe "get_latest/1" do
    test "returns the most recent checkpoint" do
      session_id = unique_session("get-latest")
      on_exit(fn -> Checkpoint.delete_all(session_id) end)

      {:ok, _} = Checkpoint.create(session_id, metadata: %{n: 1})
      :timer.sleep(10)
      {:ok, cp2} = Checkpoint.create(session_id, metadata: %{n: 2})

      assert {:ok, latest} = Checkpoint.get_latest(session_id)
      assert latest.metadata.n == 2
      assert latest.id == cp2.id
    end

    test "returns error when no checkpoints exist" do
      assert {:error, :not_found} = Checkpoint.get_latest(unique_session("no-checkpoints"))
    end
  end

  describe "delete/1" do
    test "deletes a checkpoint" do
      session_id = unique_session("delete")
      on_exit(fn -> Checkpoint.delete_all(session_id) end)

      {:ok, checkpoint} = Checkpoint.create(session_id)

      assert Checkpoint.exists?(checkpoint.id)
      assert :ok = Checkpoint.delete(checkpoint.id)
      refute Checkpoint.exists?(checkpoint.id)
    end

    test "returns ok for non-existent checkpoint" do
      assert :ok = Checkpoint.delete("chk_nonexistent")
    end
  end

  describe "delete_all/1" do
    test "deletes all checkpoints for a session" do
      session_id = unique_session("delete-all")

      {:ok, cp1} = Checkpoint.create(session_id)
      {:ok, cp2} = Checkpoint.create(session_id)
      {:ok, cp3} = Checkpoint.create(session_id)

      assert length(Checkpoint.list(session_id)) == 3

      assert {:ok, 3} = Checkpoint.delete_all(session_id)

      assert Checkpoint.list(session_id) == []
      refute Checkpoint.exists?(cp1.id)
      refute Checkpoint.exists?(cp2.id)
      refute Checkpoint.exists?(cp3.id)
    end

    test "returns 0 when no checkpoints exist" do
      assert {:ok, 0} = Checkpoint.delete_all(unique_session("no-checkpoints"))
    end
  end

  describe "stats/1" do
    test "returns checkpoint statistics" do
      session_id = unique_session("stats")
      on_exit(fn -> Checkpoint.delete_all(session_id) end)

      {:ok, cp1} = Checkpoint.create(session_id)
      :timer.sleep(10)
      {:ok, cp2} = Checkpoint.create(session_id)

      stats = Checkpoint.stats(session_id)

      assert stats.count == 2
      assert stats.newest == cp2.timestamp
      assert stats.oldest == cp1.timestamp
    end

    test "returns empty stats when no checkpoints" do
      stats = Checkpoint.stats(unique_session("no-checkpoints"))

      assert stats.count == 0
      assert stats.newest == nil
      assert stats.oldest == nil
    end
  end

  describe "exists?/1" do
    test "returns true for existing checkpoint" do
      session_id = unique_session("exists")
      on_exit(fn -> Checkpoint.delete_all(session_id) end)

      {:ok, checkpoint} = Checkpoint.create(session_id)
      assert Checkpoint.exists?(checkpoint.id)
    end

    test "returns false for non-existent checkpoint" do
      refute Checkpoint.exists?("chk_nonexistent")
    end
  end

  describe "prune/2" do
    test "keeps only specified number of checkpoints" do
      session_id = unique_session("prune")
      on_exit(fn -> Checkpoint.delete_all(session_id) end)

      # Create 5 checkpoints
      for i <- 1..5 do
        {:ok, _} = Checkpoint.create(session_id, metadata: %{n: i})
        :timer.sleep(10)
      end

      assert length(Checkpoint.list(session_id)) == 5

      # Keep only 2
      assert {:ok, 3} = Checkpoint.prune(session_id, 2)

      remaining = Checkpoint.list(session_id)
      assert length(remaining) == 2
      # Should keep the most recent (5 and 4)
      assert hd(remaining).metadata.n == 5
    end

    test "returns 0 when nothing to prune" do
      session_id = unique_session("prune-empty")

      {:ok, _} = Checkpoint.create(session_id)
      assert {:ok, 0} = Checkpoint.prune(session_id, 5)
      assert length(Checkpoint.list(session_id)) == 1

      Checkpoint.delete_all(session_id)
    end
  end

  defp unique_session(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
