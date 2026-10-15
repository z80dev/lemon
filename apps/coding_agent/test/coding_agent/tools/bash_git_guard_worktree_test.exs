defmodule CodingAgent.Tools.Bash.GitGuardWorktreeTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{TaskStore, TaskStoreServer}
  alias CodingAgent.Tools.Bash
  alias CodingAgent.Tools.Bash.GitGuard
  alias CodingAgent.Tools.Task.Worktree
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    git = System.find_executable("git") || raise "Git is required"
    git!(git, cwd, ["init", "-q", "-b", "main"])
    cwd = git!(git, cwd, ["rev-parse", "--show-toplevel"])
    git!(git, cwd, ["config", "user.name", "Guard Test"])
    git!(git, cwd, ["config", "user.email", "guard@example.invalid"])
    File.mkdir_p!(Path.join(cwd, "nested"))
    File.write!(Path.join(cwd, "nested/file"), "committed")
    git!(git, cwd, ["add", "."])

    git!(git, cwd, [
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-qm",
      "initial"
    ])

    id = TaskStore.new_task(%{})
    {:ok, workspace} = Worktree.prepare(cwd, id)
    TaskStoreServer.update_record(id, &Map.put(&1, :workspace, workspace))
    on_exit(fn -> TaskStore.delete_task(id) end)
    %{cwd: cwd, workspace: workspace, id: id}
  end

  test "recorded task worktrees and their nested cwd are exempt", %{cwd: cwd, workspace: ws} do
    assert :ok = GitGuard.check("git reset --hard", ws.cwd, [])
    assert :ok = GitGuard.check("git reset --hard", Path.join(ws.cwd, "nested"), [])
    assert :ok = GitGuard.check("git -C '#{ws.cwd}' reset --hard", cwd, [])
    assert :ok = GitGuard.check("git -C '#{ws.cwd}' -C nested reset --hard", cwd, [])
    assert {:blocked, _} = GitGuard.check("git -C '#{cwd}' reset --hard", ws.cwd, [])
    assert {:blocked, _} = GitGuard.check("git reset --hard", cwd, [])
    assert {:blocked, _} = GitGuard.check("git --work-tree='#{cwd}' reset --hard", ws.cwd, [])
    assert :ok = GitGuard.check("git -c color.ui=never reset --hard", ws.cwd, [])

    assert {:blocked, _} =
             GitGuard.check("git -c core.worktree='#{cwd}' reset --hard", ws.cwd, [])

    assert {:blocked, _} = GitGuard.check("git -ccore.worktree='#{cwd}' reset --hard", ws.cwd, [])

    assert {:blocked, _} =
             GitGuard.check("git --config-env=core.worktree=OTHER reset --hard", ws.cwd, [])
  end

  test "bash cwd exemption is effective end to end", %{cwd: cwd, workspace: ws} do
    file = Path.join(ws.cwd, "nested/file")
    File.write!(file, "uncommitted")

    assert %AgentToolResult{is_error: false} =
             Bash.execute(
               "id",
               %{"command" => "git reset --hard", "cwd" => ws.cwd},
               nil,
               nil,
               cwd,
               []
             )

    assert File.read!(file) == "committed"

    assert %AgentToolResult{is_error: true} =
             Bash.execute(
               "id",
               %{"command" => "git reset --hard", "cwd" => cwd},
               nil,
               nil,
               ws.cwd,
               []
             )
  end

  test "directory names and missing records do not grant exemption", %{workspace: ws, id: id} do
    TaskStore.delete_task(id)
    assert {:blocked, _} = GitGuard.check("git reset --hard", ws.cwd, [])
  end

  test "replaced backlinks, symlink escapes and cwd or environment ambiguity fail closed", %{
    cwd: cwd,
    workspace: ws
  } do
    File.ln_s!(cwd, Path.join(ws.cwd, "escape"))
    assert {:blocked, _} = GitGuard.check("git reset --hard", Path.join(ws.cwd, "escape"), [])
    assert {:blocked, _} = GitGuard.check("cd '#{cwd}' && git reset --hard", ws.cwd, [])
    assert {:blocked, _} = GitGuard.check("GIT_WORK_TREE='#{cwd}' git reset --hard", ws.cwd, [])

    assert {:blocked, _} =
             GitGuard.check("git reset --hard", ws.cwd, command_env: %{"GIT_WORK_TREE" => cwd})

    File.write!(Path.join(ws.cwd, ".git"), "gitdir: #{cwd}/.git\n")
    assert {:blocked, _} = GitGuard.check("git reset --hard", ws.cwd, [])
  end

  defp git!(git, cwd, args) do
    {output, status} = System.cmd(git, args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
