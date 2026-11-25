defmodule CodingAgent.CheckpointTest do
  @moduledoc """
  Tests for the Checkpoint module.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Checkpoint
  alias LemonCore.Introspection

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, original) end)
    :ok
  end

  describe "checkpoint audit events" do
    @tag :tmp_dir
    test "filesystem checkpoints emit introspection and run events", %{tmp_dir: tmp_dir} do
      session_key = unique_session("audit")
      run_id = "run_#{System.unique_integer([:positive])}"
      path = Path.join(tmp_dir, "audit.txt")
      File.write!(path, "before\n")

      on_exit(fn -> LemonAgent.Checkpoint.delete_all(session_key) end)

      :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

      {:ok, checkpoint} =
        Checkpoint.create_filesystem(session_key, [path],
          cwd: tmp_dir,
          tool: "write",
          run_id: run_id,
          session_key: session_key,
          agent_id: "agent_audit"
        )

      assert_receive %LemonCore.Event{
                       type: :checkpoint_created,
                       payload: %{checkpoint_id: checkpoint_id, checkpoint_kind: "filesystem"},
                       meta: %{run_id: ^run_id, session_key: ^session_key}
                     },
                     1_000

      assert checkpoint_id == checkpoint.id

      created =
        Introspection.list(event_type: :checkpoint_created, run_id: run_id, limit: 20)
        |> Enum.find(&(&1.payload.checkpoint_id == checkpoint.id))

      assert created.session_key == session_key
      assert created.agent_id == "agent_audit"
      assert created.payload.tool == "write"
      assert created.payload.path_count == 1

      File.write!(path, "after\n")

      {:ok, restored} =
        Checkpoint.restore_filesystem(checkpoint.id, session_key,
          run_id: run_id,
          session_key: session_key
        )

      assert restored.restored == [path]

      assert_receive %LemonCore.Event{
                       type: :checkpoint_restored,
                       payload: %{checkpoint_id: ^checkpoint_id, restored_count: 1},
                       meta: %{run_id: ^run_id, session_key: ^session_key}
                     },
                     1_000

      :ok =
        Checkpoint.delete(checkpoint.id, session_key, run_id: run_id, session_key: session_key)

      assert_receive %LemonCore.Event{
                       type: :checkpoint_deleted,
                       payload: %{checkpoint_id: ^checkpoint_id},
                       meta: %{run_id: ^run_id, session_key: ^session_key}
                     },
                     1_000

      restored_event =
        Introspection.list(event_type: :checkpoint_restored, run_id: run_id, limit: 20)
        |> Enum.find(&(&1.payload.checkpoint_id == checkpoint.id))

      assert restored_event.payload.restored_count == 1

      deleted_event =
        Introspection.list(event_type: :checkpoint_deleted, run_id: run_id, limit: 20)
        |> Enum.find(&(&1.payload.checkpoint_id == checkpoint.id))

      assert deleted_event.payload.checkpoint_kind == "filesystem"
    end
  end

  describe "list/1" do
    test "returns checkpoints sorted by timestamp" do
      session_id = unique_session("list-sorted")
      on_exit(fn -> LemonAgent.Checkpoint.delete_all(session_id) end)

      # Create multiple checkpoints
      {:ok, _cp1} = LemonAgent.Checkpoint.create(session_id, metadata: %{order: 1})
      :timer.sleep(10)
      # Ensure different timestamps
      {:ok, _cp2} = LemonAgent.Checkpoint.create(session_id, metadata: %{order: 2})
      :timer.sleep(10)
      {:ok, _cp3} = LemonAgent.Checkpoint.create(session_id, metadata: %{order: 3})

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
        LemonAgent.Checkpoint.delete_all(session_a)
        LemonAgent.Checkpoint.delete_all(session_b)
      end)

      {:ok, _} = LemonAgent.Checkpoint.create(session_a, metadata: %{session: "a"})
      {:ok, _} = LemonAgent.Checkpoint.create(session_b, metadata: %{session: "b"})

      a_checkpoints = Checkpoint.list(session_a)
      assert length(a_checkpoints) == 1
      assert hd(a_checkpoints).metadata.session == "a"
    end
  end

  describe "delete/1" do
    test "deletes a checkpoint" do
      session_id = unique_session("delete")
      on_exit(fn -> LemonAgent.Checkpoint.delete_all(session_id) end)

      {:ok, checkpoint} = LemonAgent.Checkpoint.create(session_id)

      assert LemonAgent.Checkpoint.exists?(checkpoint.id)
      assert :ok = Checkpoint.delete(checkpoint.id, session_id)
      refute LemonAgent.Checkpoint.exists?(checkpoint.id)
    end

    test "returns not_found for a well-formed non-existent checkpoint" do
      assert {:error, :not_found} = Checkpoint.delete("chk_0000000000000000", "any-owner")
    end

    test "rejects malformed checkpoint ids" do
      assert {:error, :not_found} = Checkpoint.delete("chk_nonexistent", "any-owner")
    end
  end

  describe "stats/1" do
    test "returns checkpoint statistics" do
      session_id = unique_session("stats")
      on_exit(fn -> LemonAgent.Checkpoint.delete_all(session_id) end)

      {:ok, cp1} = LemonAgent.Checkpoint.create(session_id)
      :timer.sleep(10)
      {:ok, cp2} = LemonAgent.Checkpoint.create(session_id)

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

  describe "filesystem checkpoints" do
    @tag :tmp_dir
    test "diffs and restores changed and newly-created files", %{tmp_dir: tmp_dir} do
      session_id = unique_session("filesystem")
      existing = Path.join(tmp_dir, "existing.txt")
      created = Path.join(tmp_dir, "created.txt")
      File.write!(existing, "before\n")

      on_exit(fn -> LemonAgent.Checkpoint.delete_all(session_id) end)

      {:ok, checkpoint} =
        Checkpoint.create_filesystem(session_id, [existing, created],
          cwd: tmp_dir,
          tool: "test"
        )

      File.write!(existing, "after\n")
      File.write!(created, "new\n")

      {:ok, diff} = Checkpoint.diff_filesystem(checkpoint.id, session_id)

      assert diff.changed == [existing, created]
      assert diff.output =~ "-before"
      assert diff.output =~ "+after"
      assert diff.output =~ "+new"

      {:ok, restored} = Checkpoint.restore_filesystem(checkpoint.id, session_id)

      assert restored.restored == [existing, created]
      assert File.read!(existing) == "before\n"
      refute File.exists?(created)
    end

    @tag :tmp_dir
    test "restores a selected path from a checkpoint", %{tmp_dir: tmp_dir} do
      session_id = unique_session("filesystem-selected")
      first = Path.join(tmp_dir, "first.txt")
      second = Path.join(tmp_dir, "second.txt")
      File.write!(first, "one\n")
      File.write!(second, "two\n")

      on_exit(fn -> LemonAgent.Checkpoint.delete_all(session_id) end)

      {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [first, second], cwd: tmp_dir)

      File.write!(first, "changed one\n")
      File.write!(second, "changed two\n")

      {:ok, restored} = Checkpoint.restore_filesystem(checkpoint.id, session_id, paths: [first])

      assert restored.restored == [first]
      assert File.read!(first) == "one\n"
      assert File.read!(second) == "changed two\n"
    end
  end

  defp unique_session(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
