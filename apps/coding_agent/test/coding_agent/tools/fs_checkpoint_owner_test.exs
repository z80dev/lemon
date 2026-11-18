defmodule CodingAgent.Tools.FsCheckpointOwnerTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Checkpoint
  alias CodingAgent.Tools.Edit
  alias CodingAgent.Tools.FsCheckpoint, as: CheckpointTool
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.Doctor.CheckpointDiagnostics

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Physical path: capture rejects symlinked ancestors (e.g. macOS /var).
    tmp_dir = CodingAgent.Tools.Lsp.Text.realpath(tmp_dir)
    checkpoint_dir = Path.join(tmp_dir, "checkpoints")
    workspace = Path.join(tmp_dir, "ws")
    File.mkdir_p!(workspace)
    paths = Application.get_env(:lemon_core, :paths, [])
    Application.put_env(:lemon_core, :paths, Keyword.put(paths, :checkpoint_dir, checkpoint_dir))
    on_exit(fn -> Application.put_env(:lemon_core, :paths, paths) end)
    %{ws: workspace, root: tmp_dir, checkpoint_dir: checkpoint_dir}
  end

  test "owner is the trusted session id regardless of option order" do
    for opts <- [
          [session_id: "sess", session_key: "key", run_id: "run"],
          [session_key: "key", run_id: "run", session_id: "sess"],
          [run_id: "run", session_id: "sess", session_key: "key"]
        ] do
      assert Checkpoint.owner(opts) == "sess"
    end

    assert Checkpoint.owner(session_key: "key", run_id: "run") == nil
    assert Checkpoint.owner(session_id: "", session_key: "key") == nil
  end

  test "delete_all and prune never follow a forged embedded id", %{
    root: root,
    checkpoint_dir: dir
  } do
    File.mkdir_p!(dir)
    victim = Path.join(root, "victim.json")

    for {fun, owner} <- [
          {&LemonCore.Checkpoint.delete_all/1, "forged-all"},
          {&LemonCore.Checkpoint.prune(&1, 0), "forged-prune"}
        ] do
      File.write!(victim, "{}")

      for {name, id} <- [{"chk_aaaaaaaaaaaaaaaa", "../victim"}, {"chk_bbbbbbbbbbbbbbbb", victim}] do
        File.write!(
          Path.join(dir, name <> ".json"),
          Jason.encode!(%{
            id: id,
            session_id: owner,
            timestamp: "2026-01-01T00:00:00Z",
            state: %{},
            context: %{},
            todos: [],
            metadata: %{}
          })
        )
      end

      fun.(owner)
      assert File.exists?(victim)
    end
  end

  test "capture records the session id even when session_key is ordered first", %{ws: ws} do
    path = Path.join(ws, "a.txt")
    File.write!(path, "one\n")
    args = %{"path" => path, "old_text" => "one", "new_text" => "two"}

    # Session lifecycle prepends session_key after session_id (reload order).
    opts = [session_key: "agent:victim:main", run_id: "run-1", session_id: "child-session"]
    %AgentToolResult{details: %{checkpoint_id: id}} = Edit.execute("e", args, nil, nil, ws, opts)
    assert {:ok, %{session_id: "child-session"}} = LemonCore.Checkpoint.load(id)

    # Without a trusted session id no key- or run-owned checkpoint is created.
    File.write!(path, "one\n")
    result = Edit.execute("e", args, nil, nil, ws, session_key: "agent:victim:main")
    refute Map.has_key?(result.details, :checkpoint_id)
  end

  test "a child given another session's key cannot reach that session's checkpoints", %{
    ws: ws
  } do
    victim_key = "agent:victim:main"
    path = Path.join(ws, "victim.txt")
    File.write!(path, "before\n")

    # Both a session-id-owned and a legacy key-owned checkpoint of the victim.
    {:ok, by_id} = Checkpoint.create_filesystem("victim-session", [path], cwd: ws)
    {:ok, by_key} = Checkpoint.create_filesystem(victim_key, [path], cwd: ws)
    File.write!(path, "after\n")

    for opts <- [
          [session_key: victim_key, session_id: "child-session"],
          [session_id: "child-session", session_key: victim_key, run_id: victim_key]
        ] do
      tool = CheckpointTool.tool(ws, opts)
      list = tool.execute.("l", %{"action" => "list"}, nil, nil)
      refute hd(list.content).text =~ by_id.id
      refute hd(list.content).text =~ by_key.id

      for id <- [by_id.id, by_key.id], action <- ["diff", "restore", "delete"] do
        assert {:error, "checkpoint not found"} =
                 tool.execute.("x", %{"action" => action, "checkpoint_id" => id}, nil, nil)
      end
    end

    # Key/run-only contexts have no owner at all.
    assert {:error, "fs_checkpoint requires a current session"} =
             CheckpointTool.execute("l", %{"action" => "list"}, nil, nil, ws,
               session_key: victim_key,
               run_id: victim_key
             )

    assert File.read!(path) == "after\n"
    assert LemonCore.Checkpoint.exists?(by_id.id)
    assert LemonCore.Checkpoint.exists?(by_key.id)
  end

  test "diff does not read through a pre-existing substituted parent symlink", %{
    ws: ws,
    root: root
  } do
    sub = Path.join(ws, "sub")
    File.mkdir_p!(sub)
    path = Path.join(sub, "file.txt")
    File.write!(path, "captured\n")
    {:ok, checkpoint} = Checkpoint.create_filesystem("diff-owner", [path], cwd: ws)

    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "file.txt"), "TOP-SECRET\n")
    File.rm_rf!(sub)
    File.ln_s!(outside, sub)

    assert {:ok, diff} = Checkpoint.diff_filesystem(checkpoint.id, "diff-owner")
    refute diff.output =~ "TOP-SECRET"
    assert diff.output =~ "unavailable"

    # Leaf symlink substitution is not followed either.
    File.rm!(sub)
    File.mkdir_p!(sub)
    File.ln_s!(Path.join(outside, "file.txt"), path)
    assert {:ok, diff} = Checkpoint.diff_filesystem(checkpoint.id, "diff-owner")
    refute diff.output =~ "TOP-SECRET"
  end

  test "session-scoped diagnostics only list the caller's checkpoints", %{
    ws: ws,
    checkpoint_dir: dir
  } do
    {:ok, mine} = LemonCore.Checkpoint.create("mine")
    {:ok, theirs} = LemonCore.Checkpoint.create("theirs")
    File.write!(Path.join(dir, "chk_ffffffffffffffff.json"), "not json")
    _ = ws

    scoped = CheckpointDiagnostics.summary({:session, "mine"}, checkpoint_dir: dir)
    assert Enum.map(scoped.recent, & &1.checkpoint_id) == [mine.id]
    assert scoped.count == 1
    assert scoped.invalid_count == 0

    for owner <- [nil, ""] do
      empty = CheckpointDiagnostics.summary({:session, owner}, checkpoint_dir: dir)
      assert empty.recent == [] and empty.count == 0
    end

    all = CheckpointDiagnostics.summary(:operator, checkpoint_dir: dir)
    assert Enum.sort(Enum.map(all.recent, & &1.checkpoint_id)) == Enum.sort([mine.id, theirs.id])
  end
end
