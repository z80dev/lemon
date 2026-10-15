defmodule LemonOmp.WorktreeTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  alias LemonOmp.Tools.Omp

  setup do
    use_fake_omp()
    put_app_env(:max_sessions, 4)
    cwd = workspace!()
    git!(cwd, ["init", "--quiet"])
    File.write!(Path.join(cwd, ".gitignore"), ".fake_omp*\n")
    File.write!(Path.join(cwd, "README.md"), "base\n")
    cwd = git!(cwd, ["rev-parse", "--show-toplevel"])
    git!(cwd, ["add", "."])

    git!(cwd, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "base"
    ])

    {:ok, cwd: cwd}
  end

  test "isolated start uses a managed branch, worktree and argv; clean close removes both", ctx do
    File.mkdir_p!(Path.join(ctx.cwd, "nested"))

    assert {:ok, wire} =
             LemonOmp.start(%{cwd: Path.join(ctx.cwd, "nested"), prompt: "HOLD", isolate: true})

    wt = wire["worktree"]
    assert wt["branch"] == "lemon-omp/" <> wire["id"]
    assert wt["path"] == Path.join([ctx.cwd, ".git", "lemon-omp-worktrees", wire["id"]])
    assert wt["repo"] == ctx.cwd
    assert String.starts_with?(git!(ctx.cwd, ["rev-parse", "HEAD"]), wt["base"])
    assert wire["cwd"] == wt["path"]

    assert File.read!(Path.join(wt["path"], ".fake_omp.args")) ==
             "--mode rpc --cwd #{wt["path"]}\n"

    assert git!(ctx.cwd, ["status", "--porcelain"]) == ""
    os_pid = fake_pid(wt["path"])
    kill_on_exit(os_pid)
    assert {:ok, ended} = LemonOmp.close(wire["id"])
    assert ended["worktree"]["kept"] == false
    assert ended["worktree"]["dirty"] == 0
    assert ended["worktree"]["commits"] == 0
    refute File.exists?(wt["path"])
    refute branch?(ctx.cwd, wt["branch"])
    wait_until(fn -> not os_alive?(os_pid) end)
  end

  test "parallel isolated workers get distinct paths and changes are kept", ctx do
    tasks = for _ <- 1..2, do: %{cwd: ctx.cwd, prompt: "WRITE_FILE", isolate: true}
    assert [{:ok, a}, {:ok, b}] = LemonOmp.start_many(tasks)
    refute a["cwd"] == b["cwd"]

    for wire <- [a, b] do
      assert {:ok, _, :settled} = LemonOmp.wait(wire["id"], 5_000)
      assert File.read!(Path.join(wire["cwd"], "worker.txt")) == "worker change\n"
      os_pid = fake_pid(wire["cwd"])
      kill_on_exit(os_pid)
      assert {:ok, ended} = LemonOmp.close(wire["id"])
      assert ended["worktree"]["kept"]
      assert ended["worktree"]["dirty"] == 1
      assert ended["worktree"]["commits"] == 0
      assert File.dir?(wire["cwd"])
      assert branch?(ctx.cwd, wire["worktree"]["branch"])
      assert {:ok, text} = LemonOmp.summary(wire["id"])
      assert text =~ "git merge #{wire["worktree"]["branch"]}"
      assert text =~ "uncommitted"
      wait_until(fn -> not os_alive?(os_pid) end)
    end

    refute File.exists?(Path.join(ctx.cwd, "worker.txt"))
  end

  test "committed worker changes are kept even with a clean index", ctx do
    assert {:ok, wire} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "WRITE_FILE", isolate: true})
    assert {:ok, _, :settled} = LemonOmp.wait(wire["id"], 5_000)
    git!(wire["cwd"], ["add", "worker.txt"])

    git!(wire["cwd"], [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "worker"
    ])

    assert {:ok, ended} = LemonOmp.close(wire["id"])
    assert ended["worktree"]["kept"]
    assert ended["worktree"]["dirty"] == 0
    assert ended["worktree"]["commits"] == 1
    assert branch?(ctx.cwd, wire["worktree"]["branch"])
  end

  test "invalid batch is rejected before any worktree exists", ctx do
    non_git = workspace!()

    assert {:error, :not_a_git_repo} =
             LemonOmp.start(%{cwd: non_git, prompt: "ok", isolate: true})

    assert LemonOmp.error_message(:not_a_git_repo) =~ "git work tree"

    assert {:error, :invalid_params} =
             LemonOmp.start(%{cwd: ctx.cwd, prompt: "ok", isolate: "yes"})

    assert {:error, {:invalid_task, 1, :not_a_git_repo}} =
             LemonOmp.start_many([
               %{cwd: ctx.cwd, prompt: "ok", isolate: true},
               %{cwd: non_git, prompt: "ok", isolate: true}
             ])

    refute File.exists?(Path.join(ctx.cwd, ".git/lemon-omp-worktrees"))
    assert git!(ctx.cwd, ["for-each-ref", "--format=%(refname)", "refs/heads/lemon-omp/"]) == ""
  end

  test "creation failure reports its task and rolls back its fresh branch", ctx do
    File.write!(Path.join(ctx.cwd, ".git/lemon-omp-worktrees"), "blocked")

    assert [{:error, :worktree_failed}] =
             LemonOmp.start_many([%{cwd: ctx.cwd, prompt: "ok", isolate: true}])

    assert git!(ctx.cwd, ["for-each-ref", "--format=%(refname)", "refs/heads/lemon-omp/"]) == ""
    refute File.exists?(Path.join(ctx.cwd, ".fake_omp.pid"))
  end

  test "admission failure also cleans an already-created worktree", ctx do
    put_app_env(:max_sessions, 1)
    assert {:ok, running} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "HOLD"})

    assert {:error, :too_many_sessions} =
             LemonOmp.start(%{cwd: ctx.cwd, prompt: "ok", isolate: true})

    assert git!(ctx.cwd, ["for-each-ref", "--format=%(refname)", "refs/heads/lemon-omp/"]) == ""
    assert {:ok, _} = LemonOmp.close(running["id"])
  end

  test "idle timeout, omp exit and hard Session crash clean owned worktrees", ctx do
    put_app_env(:idle_timeout_ms, 100)
    assert {:ok, idle} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "done", isolate: true})
    ended = await_wire(idle["id"], &(get_in(&1, ["worktree", "kept"]) == false))
    assert ended["exit"]["reason"] == "idle_timeout"
    refute File.exists?(idle["cwd"])

    put_app_env(:idle_timeout_ms, 0)

    for terminal_published <- [false, true] do
      assert {:ok, killed} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "HOLD", isolate: true})
      os_pid = fake_pid(killed["cwd"])
      kill_on_exit(os_pid)
      pid = session_pid(killed["id"])

      if terminal_published do
        # Exit handlers can publish a terminal status before terminate cleans.
        LemonOmp.Manager.publish(pid, Map.put(killed, "status", "failed"), "exited")
      end

      Process.exit(pid, :kill)
      ended = await_wire(killed["id"], &(get_in(&1, ["worktree", "kept"]) == false))
      assert ended["status"] == "failed"
      wait_until(fn -> not os_alive?(os_pid) end)
      refute File.exists?(killed["cwd"])
    end

    assert {:ok, exited} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "HOLD", isolate: true})
    pid = fake_pid(exited["cwd"])
    kill_on_exit(pid)
    System.cmd("kill", ["-TERM", to_string(pid)])
    await_wire(exited["id"], &(get_in(&1, ["worktree", "kept"]) == false))
    refute File.exists?(exited["cwd"])
  end

  test "tool batch isolation defaults can be overridden per task", ctx do
    result =
      Omp.execute(
        "isolate",
        %{
          "action" => "start_many",
          "isolate" => true,
          "tasks" => [%{"prompt" => "HOLD"}, %{"prompt" => "HOLD", "isolate" => false}]
        },
        nil,
        nil,
        cwd: ctx.cwd,
        session_key: "agent:worktrees"
      )

    refute result.is_error
    assert [a, b] = result.details["sessions"]
    assert a["worktree"]
    assert b["worktree"] == nil
    assert b["cwd"] == ctx.cwd
    assert hd(result.content).text =~ "git merge #{a["worktree"]["branch"]}"
    assert {:ok, _} = LemonOmp.close(a["id"])
    assert {:ok, _} = LemonOmp.close(b["id"])
  end

  test "resuming without isolation uses the given kept cwd", ctx do
    assert {:ok, wire} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "WRITE_FILE", isolate: true})
    assert {:ok, _, :settled} = LemonOmp.wait(wire["id"], 5_000)
    assert {:ok, _} = LemonOmp.close(wire["id"])
    assert {:ok, resumed} = LemonOmp.start(%{cwd: wire["cwd"], resume: "fake-session-0001"})
    assert resumed["cwd"] == wire["cwd"]
    assert resumed["worktree"] == nil
    assert {:ok, _} = LemonOmp.close(resumed["id"])
    assert File.dir?(wire["cwd"])
  end

  defp git!(cwd, args) do
    assert {output, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp branch?(cwd, branch) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", cwd, "show-ref", "--verify", "refs/heads/" <> branch],
        stderr_to_stdout: true
      )
    )
  end
end
