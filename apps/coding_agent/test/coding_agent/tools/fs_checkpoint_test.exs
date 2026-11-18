defmodule CodingAgent.Tools.FsCheckpointTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Checkpoint
  alias CodingAgent.Tools.Edit
  alias CodingAgent.Tools.FsCheckpoint, as: CheckpointTool
  alias CodingAgent.Tools.Patch
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  test "lists, diffs, restores, and deletes filesystem checkpoints", %{tmp_dir: tmp_dir} do
    session_id = "checkpoint-tool-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "file.txt")
    File.write!(path, "before\n")

    on_exit(fn -> LemonCore.Checkpoint.delete_all(session_id) end)

    {:ok, checkpoint} =
      Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir, tool: "test")

    File.write!(path, "after\n")

    list = execute(tmp_dir, %{"action" => "list"}, session_id)
    assert %AgentToolResult{} = list
    assert hd(list.content).text =~ checkpoint.id

    diff = execute(tmp_dir, %{"action" => "diff", "checkpoint_id" => checkpoint.id}, session_id)
    assert hd(diff.content).text =~ "-before"
    assert hd(diff.content).text =~ "+after"

    restore =
      execute(tmp_dir, %{"action" => "restore", "checkpoint_id" => checkpoint.id}, session_id)

    assert restore.details.restored == [path]
    assert File.read!(path) == "before\n"

    delete =
      execute(tmp_dir, %{"action" => "delete", "checkpoint_id" => checkpoint.id}, session_id)

    assert delete.details.deleted
    refute LemonCore.Checkpoint.exists?(checkpoint.id)
  end

  test "traversal and absolute checkpoint ids are rejected and touch nothing", %{
    tmp_dir: tmp_dir
  } do
    session_id = "checkpoint-traversal-#{System.unique_integer([:positive])}"
    target = Path.join(tmp_dir, "victim.txt")
    File.write!(target, "current\n")

    # A forged filesystem checkpoint outside the checkpoint dir, owned by the
    # caller's session so ownership alone would not stop it.
    forged = Path.join(tmp_dir, "forged.json")

    File.write!(
      forged,
      Jason.encode!(%{
        id: "forged",
        session_id: session_id,
        timestamp: DateTime.to_iso8601(DateTime.utc_now()),
        state: %{
          filesystem: %{
            cwd: tmp_dir,
            roots: [target],
            files: [
              %{
                path: target,
                exists: true,
                type: "regular",
                size: 7,
                mode: 0o100644,
                content_b64: Base.encode64("forged\n")
              }
            ]
          }
        },
        context: %{},
        todos: [],
        metadata: %{kind: "filesystem"}
      })
    )

    up = String.duplicate("../", length(Path.split(LemonCore.Checkpoint.checkpoint_dir())))
    traversal = up <> String.trim_leading(Path.rootname(forged), "/")
    absolute = Path.rootname(forged)

    for id <- [traversal, absolute, "chk_../../x", "chk_0123456789abcdef\n"],
        action <- ["diff", "restore", "delete"] do
      assert {:error, _} =
               execute(tmp_dir, %{"action" => action, "checkpoint_id" => id}, session_id),
             "#{action} accepted #{inspect(id)}"

      assert File.read!(target) == "current\n"
      assert File.exists?(forged)
    end

    for id <- [traversal, absolute] do
      assert {:error, :not_found} = LemonCore.Checkpoint.load(id)
      assert {:error, :not_found} = LemonCore.Checkpoint.restore_filesystem(id, session_id)
      assert {:error, :not_found} = LemonCore.Checkpoint.delete(id, session_id)
      refute LemonCore.Checkpoint.exists?(id)
    end

    assert File.read!(target) == "current\n"
    assert File.exists?(forged)
  end

  test "checkpoints owned by another session are not found for every action", %{
    tmp_dir: tmp_dir
  } do
    owner = "checkpoint-owner-#{System.unique_integer([:positive])}"
    intruder = "checkpoint-intruder-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "owned.txt")
    File.write!(path, "before\n")

    on_exit(fn -> LemonCore.Checkpoint.delete_all(owner) end)

    {:ok, checkpoint} = Checkpoint.create_filesystem(owner, [path], cwd: tmp_dir, tool: "test")
    File.write!(path, "after\n")

    for action <- ["diff", "restore", "delete"] do
      assert {:error, "checkpoint not found"} =
               execute(tmp_dir, %{"action" => action, "checkpoint_id" => checkpoint.id}, intruder)
    end

    # The model cannot widen `list` to another session.
    list = execute(tmp_dir, %{"action" => "list", "session_id" => owner}, intruder)
    refute hd(list.content).text =~ checkpoint.id
    refute Map.has_key?(CheckpointTool.tool(tmp_dir).parameters["properties"], "session_id")

    assert File.read!(path) == "after\n"
    assert LemonCore.Checkpoint.exists?(checkpoint.id)

    assert {:error, "fs_checkpoint requires a current session"} =
             CheckpointTool.execute("call_1", %{"action" => "list"}, nil, nil, tmp_dir, [])

    restore =
      execute(tmp_dir, %{"action" => "restore", "checkpoint_id" => checkpoint.id}, owner)

    assert restore.details.restored == [path]
  end

  test "crafted snapshots outside the recorded roots are rejected", %{tmp_dir: tmp_dir} do
    session_id = "checkpoint-roots-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "inside.txt")
    outside = Path.join(tmp_dir, "outside.txt")
    File.write!(path, "inside\n")
    File.write!(outside, "outside\n")

    on_exit(fn -> LemonCore.Checkpoint.delete_all(session_id) end)

    {:ok, checkpoint} =
      Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir, tool: "test")

    file = Path.join(LemonCore.Checkpoint.checkpoint_dir(), checkpoint.id <> ".json")
    stored = Jason.decode!(File.read!(file))

    evil = %{
      "path" => outside,
      "exists" => true,
      "type" => "regular",
      "size" => 6,
      "mode" => 0o100644,
      "content_b64" => Base.encode64("owned\n")
    }

    variants = [
      # Extra snapshot path not among the recorded roots.
      update_in(stored, ["state", "filesystem", "files"], &(&1 ++ [evil])),
      # Legacy/forged checkpoint without recorded roots.
      update_in(stored, ["state", "filesystem"], &Map.delete(&1, "roots")),
      # Root path with traversal segments.
      stored
      |> put_in(["state", "filesystem", "roots"], [path <> "/../outside.txt"])
      |> put_in(["state", "filesystem", "files"], [
        Map.put(evil, "path", path <> "/../outside.txt")
      ])
    ]

    for variant <- variants do
      File.write!(file, Jason.encode!(variant))

      for action <- ["diff", "restore"] do
        assert {:error, _} =
                 execute(
                   tmp_dir,
                   %{"action" => action, "checkpoint_id" => checkpoint.id},
                   session_id
                 )
      end

      assert File.read!(outside) == "outside\n"
      assert File.read!(path) == "inside\n"
    end
  end

  test "edit creates a restorable filesystem checkpoint when session opts are present", %{
    tmp_dir: tmp_dir
  } do
    session_id = "edit-checkpoint-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "edit.txt")
    File.write!(path, "alpha\nbeta\n")

    on_exit(fn -> LemonCore.Checkpoint.delete_all(session_id) end)

    result =
      Edit.execute(
        "call_1",
        %{"path" => path, "old_text" => "beta", "new_text" => "gamma"},
        nil,
        nil,
        tmp_dir,
        session_id: session_id
      )

    assert %AgentToolResult{details: %{checkpoint_id: checkpoint_id}} = result
    assert File.read!(path) == "alpha\ngamma\n"

    {:ok, _restored} = Checkpoint.restore_filesystem(checkpoint_id, session_id)
    assert File.read!(path) == "alpha\nbeta\n"
  end

  test "patch creates one checkpoint for all affected paths", %{tmp_dir: tmp_dir} do
    session_id = "patch-checkpoint-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "patch.txt")
    File.write!(path, "before\n")

    on_exit(fn -> LemonCore.Checkpoint.delete_all(session_id) end)

    patch = "*** Begin Patch\n*** Update File: patch.txt\n@@\n-before\n+after\n*** End Patch\n"

    result =
      Patch.execute("call_1", %{"patch_text" => patch}, nil, nil, tmp_dir, session_id: session_id)

    assert %AgentToolResult{details: %{checkpoint_id: checkpoint_id, changed: [^path]}} = result
    assert File.read!(path) == "after\n"

    {:ok, _restored} = Checkpoint.restore_filesystem(checkpoint_id, session_id)
    assert File.read!(path) == "before\n"
  end

  defp execute(cwd, params, session_id) do
    CheckpointTool.execute("call_1", params, nil, nil, cwd, session_id: session_id)
  end
end
