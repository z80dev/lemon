defmodule CodingAgent.Tools.CheckpointTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias CodingAgent.Checkpoint
  alias CodingAgent.Tools.Checkpoint, as: CheckpointTool
  alias CodingAgent.Tools.Edit
  alias CodingAgent.Tools.Patch

  @moduletag :tmp_dir

  test "lists, diffs, restores, and deletes filesystem checkpoints", %{tmp_dir: tmp_dir} do
    session_id = "checkpoint-tool-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "file.txt")
    File.write!(path, "before\n")

    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    {:ok, checkpoint} =
      Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir, tool: "test")

    File.write!(path, "after\n")

    list = execute(tmp_dir, %{"action" => "list", "session_id" => session_id})
    assert %AgentToolResult{} = list
    assert hd(list.content).text =~ checkpoint.id

    diff = execute(tmp_dir, %{"action" => "diff", "checkpoint_id" => checkpoint.id})
    assert hd(diff.content).text =~ "-before"
    assert hd(diff.content).text =~ "+after"

    restore = execute(tmp_dir, %{"action" => "restore", "checkpoint_id" => checkpoint.id})
    assert restore.details.restored == [path]
    assert File.read!(path) == "before\n"

    delete = execute(tmp_dir, %{"action" => "delete", "checkpoint_id" => checkpoint.id})
    assert delete.details.deleted
    refute Checkpoint.exists?(checkpoint.id)
  end

  test "edit creates a restorable filesystem checkpoint when session opts are present", %{
    tmp_dir: tmp_dir
  } do
    session_id = "edit-checkpoint-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "edit.txt")
    File.write!(path, "alpha\nbeta\n")

    on_exit(fn -> Checkpoint.delete_all(session_id) end)

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

    {:ok, _restored} = Checkpoint.restore_filesystem(checkpoint_id)
    assert File.read!(path) == "alpha\nbeta\n"
  end

  test "patch creates one checkpoint for all affected paths", %{tmp_dir: tmp_dir} do
    session_id = "patch-checkpoint-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "patch.txt")
    File.write!(path, "before\n")

    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    patch = "*** Begin Patch\n*** Update File: patch.txt\n@@\n-before\n+after\n*** End Patch\n"

    result =
      Patch.execute("call_1", %{"patch_text" => patch}, nil, nil, tmp_dir, session_id: session_id)

    assert %AgentToolResult{details: %{checkpoint_id: checkpoint_id, changed: [^path]}} = result
    assert File.read!(path) == "after\n"

    {:ok, _restored} = Checkpoint.restore_filesystem(checkpoint_id)
    assert File.read!(path) == "before\n"
  end

  defp execute(cwd, params) do
    CheckpointTool.execute("call_1", params, nil, nil, cwd, [])
  end
end
