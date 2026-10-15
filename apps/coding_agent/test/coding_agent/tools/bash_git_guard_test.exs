defmodule CodingAgent.Tools.Bash.GitGuardTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Artifacts
  alias CodingAgent.Tools.Bash
  alias CodingAgent.Tools.Bash.GitGuard
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    # Keep regression failures from targeting the source repository above tmp_dir.
    assert {_, 0} = System.cmd("git", ["init", "-q", cwd], stderr_to_stdout: true)
    :ok
  end

  for command <- [
        "git reset --hard",
        "git reset --hard HEAD~1",
        "git checkout -- file",
        "git checkout .",
        "git checkout -f main",
        "git checkout --force main",
        "git restore file",
        "git restore --worktree file",
        "git restore --staged --worktree file",
        "git restore -SW file",
        "git clean -f",
        "git clean -fdx",
        "git clean --force",
        "git stash drop",
        "git stash clear",
        "git push --force",
        "git push -f origin main",
        "git push --force-if-includes",
        "git branch -D old",
        "git worktree remove --force path",
        "git worktree remove -f path",
        "git switch --discard-changes main",
        "git switch -f main"
      ] do
    test "blocks #{command}", %{tmp_dir: cwd} do
      assert {:blocked, message} = GitGuard.check(unquote(command), cwd, [])
      assert message =~ "Blocked git"
      assert message =~ "git_guard = false"
    end
  end

  test "allows non-destructive lookalikes", %{tmp_dir: cwd} do
    for command <- [
          "git reset --soft HEAD~1",
          "git reset --merge",
          "git reset --keep",
          "git restore --staged file",
          "git restore -S file",
          "git push --force-with-lease",
          "git push -f --force-with-lease=main:abc",
          "git push --force-if-includes --force-with-lease",
          "git checkout -b x",
          "git checkout main",
          "echo 'git reset --hard'",
          "echo '$(git reset --hard)'",
          "git clean -n",
          "git branch -d old",
          "git stash list",
          "git switch main",
          "git reset -- --hard"
        ] do
      assert :ok = GitGuard.check(command, cwd, []), command
    end
  end

  test "handles global options, prefixes and command boundaries", %{tmp_dir: cwd} do
    for command <- [
          "git -C dir reset --hard",
          "git -Cdir -c a=b --no-pager reset --hard",
          "git -c alias.foo=bar --literal-pathspecs checkout -- file",
          "git --git-dir=.git clean -fd",
          "git --work-tree=dir reset --hard",
          "FOO=1 sudo -u root command git -c x=y reset --hard",
          "true && git reset --hard",
          "false || git clean -f",
          "echo x; git stash clear",
          "true\ngit branch -D x",
          "echo $(git reset --hard)",
          ~s|echo "$(git reset --hard)"|,
          "echo `git reset --hard`",
          "(git reset --hard)",
          "git reset --hard | head"
        ] do
      assert {:blocked, _} = GitGuard.check(command, cwd, []), command
    end
  end

  test "config disables guard", %{tmp_dir: cwd} do
    assert :ok = GitGuard.check("git reset --hard", cwd, bash_config: %{git_guard: false})
    assert :ok = GitGuard.check("git reset --hard", cwd, bash_config: %{"git_guard" => false})
  end

  test "all launch modes refuse before earlier side effects", %{tmp_dir: cwd} do
    marker = Path.join(cwd, "started")

    for mode <- [%{}, %{"run_in_background" => true}, %{"name" => "blocked-git"}] do
      params = Map.merge(%{"command" => "touch #{marker}; git reset --hard"}, mode)

      assert %AgentToolResult{is_error: true, content: [%{text: text} | _]} =
               Bash.execute("id", params, nil, nil, cwd, [])

      assert text =~ "Blocked git reset --hard"
      refute File.exists?(marker)
    end
  end

  test "internal URL expansion precedes guard matching", %{tmp_dir: cwd} do
    opts = [session_id: "git-guard", context_guardrails: %{spill_dir: Path.join(cwd, "spill")}]
    {:ok, uri} = Artifacts.spill("path", cwd, opts)

    assert %AgentToolResult{is_error: true, content: [%{text: text} | _]} =
             Bash.execute("id", %{"command" => "git checkout -- #{uri}"}, nil, nil, cwd, opts)

    assert text =~ "Blocked git checkout"
  end
end
