defmodule CodingAgent.AutomaticGitSafetyTest do
  # Repositories a user opens (an unpacked archive, a shared checkout, a tree
  # an agent wrote into) carry configuration that names programs. The Git
  # reads Lemon runs on its own (session-start environment, per-turn status,
  # ignore filtering, origin lookup) must run none of them.
  use ExUnit.Case, async: false

  alias CodingAgent.SystemPrompt.Environment
  alias CodingAgent.Tools.IgnoreFilter

  @moduletag :tmp_dir

  test "session-start capture runs no repository fsmonitor program", %{tmp_dir: tmp} do
    repo = repo!(Path.join(tmp, "repo"))
    marker = Path.join(tmp, "fsmonitor-ran")
    git!(repo, ["config", "core.fsmonitor", program!(tmp, "fsmonitor", marker, "exit 1")])

    block = Environment.capture(repo, date: ~D[2026-01-02])

    assert block =~ "Git worktree root: #{repo}"
    assert block =~ ~s(- "tracked.txt")
    refute File.exists?(marker), "session-start Git ran the repository's fsmonitor program"
  end

  test "turn status runs no fsmonitor program or clean filter", %{tmp_dir: tmp} do
    repo = repo!(Path.join(tmp, "repo"))
    fsmonitor = Path.join(tmp, "fsmonitor-ran")
    filter = Path.join(tmp, "filter-ran")
    git!(repo, ["config", "core.fsmonitor", program!(tmp, "fsmonitor", fsmonitor, "exit 1")])
    git!(repo, ["config", "filter.evil.clean", program!(tmp, "clean", filter, "cat")])
    File.write!(Path.join(repo, ".git/info/attributes"), "* filter=evil\n")
    # A stat change makes status hash the file, which runs its clean filter.
    File.touch!(Path.join(repo, "tracked.txt"), {{2020, 1, 1}, {0, 0, 0}})

    body = Environment.turn_section(repo, date: ~D[2026-01-02]).body

    assert body =~ "Git repository: yes (branch: main)"
    refute File.exists?(fsmonitor), "turn status ran the repository's fsmonitor program"
    refute File.exists?(filter), "turn status ran the repository's clean filter"
  end

  test "a .git file redirect cannot select programs either", %{tmp_dir: tmp} do
    repo = Path.join(tmp, "project")
    git_dir = Path.join(tmp, "elsewhere.git")
    {_, 0} = System.cmd(git(), ["init", "-q", "-b", "main", "--separate-git-dir", git_dir, repo])
    commit!(repo)
    assert File.regular?(Path.join(repo, ".git"))
    marker = Path.join(tmp, "fsmonitor-ran")
    git!(repo, ["config", "core.fsmonitor", program!(tmp, "fsmonitor", marker, "exit 1")])

    block = Environment.capture(repo, date: ~D[2026-01-02])
    body = Environment.turn_section(repo, date: ~D[2026-01-02]).body

    assert block =~ ~s(- "tracked.txt")
    assert body =~ "Git repository: yes (branch: main)"
    refute File.exists?(marker), "Git followed the redirect and ran its fsmonitor program"
  end

  test "ignore filtering runs no repository program", %{tmp_dir: tmp} do
    repo = repo!(Path.join(tmp, "repo"))
    marker = Path.join(tmp, "fsmonitor-ran")
    git!(repo, ["config", "core.fsmonitor", program!(tmp, "fsmonitor", marker, "exit 1")])
    File.write!(Path.join(repo, ".gitignore"), "ignored.txt\n")
    File.write!(Path.join(repo, "ignored.txt"), "x")

    kept =
      IgnoreFilter.reject_ignored(
        [Path.join(repo, "ignored.txt"), Path.join(repo, "tracked.txt")],
        repo
      )

    assert kept == [Path.join(repo, "tracked.txt")]
    refute File.exists?(marker)
  end

  test "inherited Git environment cannot redirect automatic Git", %{tmp_dir: tmp} do
    repo = repo!(Path.join(tmp, "repo"))
    other = repo!(Path.join(tmp, "other"))
    File.write!(Path.join(other, "only-in-other.txt"), "x")
    git!(other, ["add", "only-in-other.txt"])

    with_env([{"GIT_DIR", Path.join(other, ".git")}, {"GIT_WORK_TREE", other}], fn ->
      block = Environment.capture(repo, date: ~D[2026-01-02])
      assert block =~ ~s(- "tracked.txt")
      refute block =~ "only-in-other.txt"
    end)
  end

  test "a git planted on PATH never runs at session start or turn start", %{tmp_dir: tmp} do
    repo = repo!(Path.join(tmp, "repo"))
    marker = Path.join(tmp, "planted-git-ran")
    File.mkdir_p!(Path.join(repo, "bin"))
    # Absolute workspace entry, relative entry and empty entry (cwd = repo).
    program!(Path.join(repo, "bin"), "git", marker, "echo 'git version 9.9.9'")
    program!(repo, "git", marker, "echo 'git version 9.9.9'")
    path = "#{repo}/bin:bin::#{System.get_env("PATH")}"

    File.cd!(repo, fn ->
      with_env([{"PATH", path}], fn ->
        assert Environment.capture(repo, date: ~D[2026-01-02]) =~ ~s(- "tracked.txt")
        assert Environment.turn_section(repo).body =~ "Git repository: yes (branch: main)"
      end)
    end)

    refute File.exists?(marker), "automatic Git ran an executable found on PATH"
  end

  defp with_env(vars, fun) do
    previous = Enum.map(vars, fn {name, _} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  defp git, do: System.find_executable("git") || flunk("Git is required")

  defp git!(repo, args) do
    {out, 0} = System.cmd(git(), ["-C", repo | args], stderr_to_stdout: true)
    out
  end

  defp repo!(dir) do
    {_, 0} = System.cmd(git(), ["init", "-q", "-b", "main", dir])
    commit!(dir)
    dir
  end

  defp commit!(dir) do
    File.write!(Path.join(dir, "tracked.txt"), "tracked\n")
    git!(dir, ["add", "tracked.txt"])

    git!(dir, [
      "-c",
      "user.name=T",
      "-c",
      "user.email=t@example.invalid",
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "-qm",
      "init"
    ])
  end

  defp program!(dir, name, marker, tail) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n: > '#{marker}'\n#{tail}\n")
    File.chmod!(path, 0o755)
    path
  end
end
