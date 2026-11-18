defmodule LemonCore.SafeGitTest do
  use ExUnit.Case, async: false

  alias LemonCore.SafeGit

  @moduletag :tmp_dir

  describe "repository/1" do
    test "locates the repository from a nested directory with file reads", %{tmp_dir: tmp} do
      repo = repo!(Path.join(tmp, "repo"))
      nested = Path.join(repo, "a/b")
      File.mkdir_p!(nested)

      assert {:ok, %{root: ^repo, git_dir: git_dir, common_dir: git_dir}} =
               SafeGit.repository(nested)

      assert git_dir == Path.join(repo, ".git")
    end

    test "a linked worktree uses its administrative and common directories", %{tmp_dir: tmp} do
      repo = repo!(Path.join(tmp, "repo"))
      linked = Path.join(tmp, "linked")
      git!(repo, ["worktree", "add", "-q", "-b", "feature", linked])

      assert {:ok, %{root: ^linked, git_dir: admin, common_dir: common}} =
               SafeGit.repository(linked)

      assert common == Path.join(repo, ".git")
      assert Path.dirname(admin) == Path.join(common, "worktrees")

      assert {:ok, "feature\n", 0} =
               SafeGit.run(elem(SafeGit.repository(linked), 1), [
                 "rev-parse",
                 "--abbrev-ref",
                 "HEAD"
               ])
    end

    test "a plain directory or an empty marker is not a repository" do
      dir = Path.join(System.tmp_dir!(), "lemon-safe-git-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert SafeGit.repository(dir) == :not_repository
      File.write!(Path.join(dir, ".git"), "")
      assert SafeGit.repository(dir) == :not_repository
    end
  end

  describe "run/3" do
    test "drivers from the repository's configuration or its includes never run", %{tmp_dir: tmp} do
      repo = repo!(Path.join(tmp, "repo"))
      File.write!(Path.join(repo, "other.txt"), "other\n")
      git!(repo, ["add", "other.txt"])
      marker = Path.join(tmp, "program-ran")
      clean = program!(tmp, "clean", marker, "cat")
      included = Path.join(tmp, "included.gitconfig")
      File.write!(included, "[filter \"Included\"]\n\tclean = #{clean}\n")
      git!(repo, ["config", "filter.Evil.clean", clean])
      git!(repo, ["config", "include.path", included])

      File.write!(
        Path.join(repo, ".git/info/attributes"),
        "tracked.txt filter=Evil\nother.txt filter=Included\n"
      )

      for file <- ["tracked.txt", "other.txt"],
          do: File.touch!(Path.join(repo, file), {{2020, 1, 1}, {0, 0, 0}})

      {:ok, safe} = SafeGit.repository(repo)
      assert {:ok, _out, 0} = SafeGit.run(safe, ["status", "--porcelain"])
      refute File.exists?(marker)
    end

    test "a concurrently replaced include cannot introduce a driver", %{tmp_dir: tmp} do
      repo = repo!(Path.join(tmp, "repo"))
      marker = Path.join(tmp, "program-ran")
      clean = program!(tmp, "clean", marker, "cat")
      included = Path.join(tmp, "included.gitconfig")
      benign = "[core]\n\tquotepath = false\n"
      evil = "[filter \"late\"]\n\tclean = #{clean}\n"
      File.write!(included, benign)
      git!(repo, ["config", "include.path", included])
      # A name `-c` could never express is irrelevant: configuration is not read.
      git!(repo, ["config", "filter.a=b.clean", clean])
      File.write!(Path.join(repo, ".git/info/attributes"), "* filter=late\n* filter=a=b\n")
      {:ok, safe} = SafeGit.repository(repo)

      flipper =
        Task.async(fn ->
          for i <- 1..400, do: File.write!(included, if(rem(i, 2) == 0, do: benign, else: evil))
        end)

      for second <- 1..20 do
        File.touch!(Path.join(repo, "tracked.txt"), {{2020, 1, 1}, {0, 0, second}})
        assert {:ok, _out, 0} = SafeGit.run(safe, ["status", "--porcelain"])
      end

      Task.await(flipper)
      refute File.exists?(marker)

      # The payload is live: plain Git with the same repository runs it.
      File.write!(included, evil)
      File.touch!(Path.join(repo, "tracked.txt"), {{2021, 1, 1}, {0, 0, 0}})
      System.cmd("git", ["-C", repo, "status", "--porcelain"], stderr_to_stdout: true)
      assert File.exists?(marker)
    end

    test "a commondir rewritten after validation is never consulted", %{tmp_dir: tmp} do
      repo = repo!(Path.join(tmp, "repo"))
      linked = Path.join(tmp, "linked")
      git!(repo, ["worktree", "add", "-q", "-b", "feature", linked])
      evil = repo!(Path.join(tmp, "evil"))
      marker = Path.join(tmp, "program-ran")
      git!(evil, ["config", "core.fsmonitor", program!(tmp, "fsmonitor", marker, "exit 1")])
      {:ok, safe} = SafeGit.repository(linked)

      File.write!(Path.join(safe.git_dir, "commondir"), Path.join(evil, ".git") <> "\n")

      assert {:ok, "## feature\n", 0} = SafeGit.run(safe, ["status", "--porcelain", "--branch"])
      refute File.exists?(marker)
    end

    test "never recurses into a submodule with its own configuration", %{tmp_dir: tmp} do
      sub_source = repo!(Path.join(tmp, "sub-source"))
      repo = repo!(Path.join(tmp, "repo"))

      git!(repo, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub_source, "sub"])

      commit!(repo, "add submodule")
      marker = Path.join(tmp, "program-ran")
      sub = Path.join(repo, "sub")
      git!(sub, ["config", "core.fsmonitor", program!(tmp, "fsmonitor", marker, "exit 1")])
      git!(sub, ["config", "filter.sub.clean", program!(tmp, "clean", marker, "cat")])
      File.write!(Path.join(repo, ".git/modules/sub/info/attributes"), "* filter=sub\n")
      File.touch!(Path.join(sub, "tracked.txt"), {{2020, 1, 1}, {0, 0, 0}})

      {:ok, safe} = SafeGit.repository(repo)
      assert {:ok, _, 0} = SafeGit.run(safe, ["status", "--porcelain"])
      assert {:ok, _, 0} = SafeGit.run(safe, ["diff", "HEAD"])
      refute File.exists?(marker)
    end

    test "inherited Git environment does not reach the command", %{tmp_dir: tmp} do
      repo = repo!(Path.join(tmp, "repo"))
      File.write!(Path.join(repo, "tracked.txt"), "changed\n")
      marker = Path.join(tmp, "program-ran")
      external = program!(tmp, "external-diff", marker, "exit 0")
      fsmonitor = program!(tmp, "fsmonitor", marker, "exit 1")
      {:ok, safe} = SafeGit.repository(repo)

      with_env(
        [
          {"GIT_EXTERNAL_DIFF", external},
          {"GIT_CONFIG_PARAMETERS", "'core.fsmonitor'='#{fsmonitor}'"},
          {"GIT_CONFIG_COUNT", "1"},
          {"GIT_CONFIG_KEY_0", "core.fsmonitor"},
          {"GIT_CONFIG_VALUE_0", fsmonitor}
        ],
        fn -> assert {:ok, _diff, 0} = SafeGit.run(safe, ["diff"]) end
      )

      refute File.exists?(marker)
    end

    test "refuses commands outside its read-only set" do
      repo = %{
        root: "/nonexistent",
        git_dir: "/nonexistent/.git",
        common_dir: "/nonexistent/.git"
      }

      for args <- [
            ["commit", "-m", "x"],
            ["remote", "add", "x", "y"],
            ["ls-files", "--recurse-submodules"],
            ["describe", "--dirty"],
            ["-c", "core.fsmonitor=x", "status"]
          ] do
        assert SafeGit.run(repo, args) == {:error, :unsupported_command}
      end
    end

    test "kills a command past its deadline and refuses a cwd outside the work tree", %{
      tmp_dir: tmp
    } do
      repo = repo!(Path.join(tmp, "repo"))
      slow = program!(tmp, "slow-git", Path.join(tmp, "slow-ran"), "exec sleep 5")
      {:ok, safe} = SafeGit.repository(repo)

      started = System.monotonic_time(:millisecond)
      assert SafeGit.run(safe, ["status"], git: slow, timeout_ms: 50) == {:error, :timeout}
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert SafeGit.run(safe, ["status"], cd: tmp) == {:error, :outside_repository}
    end

    test "git comes from fixed system directories, never PATH", %{tmp_dir: tmp} do
      repo = repo!(Path.join(tmp, "repo"))
      workspace = Path.join(tmp, "workspace")
      marker = Path.join(tmp, "planted-git-ran")
      File.mkdir_p!(Path.join(workspace, "bin"))
      planted = "echo 'git version 9.9.9'"
      program!(Path.join(workspace, "bin"), "git", marker, planted)
      program!(workspace, "git", marker, planted)
      {:ok, safe} = SafeGit.repository(repo)

      # An absolute workspace entry, a relative entry and an empty entry (the
      # current directory), each ahead of the real installation.
      path = "#{workspace}/bin:bin::#{System.get_env("PATH")}"

      File.cd!(workspace, fn ->
        with_env([{"PATH", path}], fn ->
          assert {:ok, git} = SafeGit.executable()
          assert Path.dirname(git) in ~w(/usr/bin /usr/local/bin /opt/homebrew/bin /bin)
          assert {:ok, _out, 0} = SafeGit.run(safe, ["status", "--porcelain"])
        end)
      end)

      refute File.exists?(marker)
    end

    test "refuses an executable inside the repository and Git older than 2.31", %{tmp_dir: tmp} do
      repo = repo!(Path.join(tmp, "repo"))
      {:ok, safe} = SafeGit.repository(repo)
      inside = program!(repo, "git-inside", Path.join(tmp, "inside-ran"), "exit 0")
      old = program!(tmp, "old-git", Path.join(tmp, "old-ran"), "echo 'git version 2.30.9'")

      assert SafeGit.run(safe, ["status"], git: inside) == {:error, :untrusted_git}
      refute File.exists?(Path.join(tmp, "inside-ran"))
      assert SafeGit.run(safe, ["status"], git: old) == {:error, :unsupported_git_version}
    end
  end

  describe "discovery" do
    test "FIFO metadata fails closed within the deadline instead of blocking" do
      base =
        Path.join(System.tmp_dir!(), "lemon-safe-git-fifo-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(base) end)

      # A HEAD with no local store sends discovery to `commondir`.
      commondir = Path.join(base, "commondir-fifo")
      File.mkdir_p!(Path.join(commondir, ".git"))
      File.write!(Path.join(commondir, ".git/HEAD"), "ref: refs/heads/main\n")
      {_, 0} = System.cmd("mkfifo", [Path.join(commondir, ".git/commondir")])

      # A `.git` file whose `gitdir:` target holds the same FIFO.
      gitfile = Path.join(base, "gitfile")
      File.mkdir_p!(gitfile)
      File.write!(Path.join(gitfile, ".git"), "gitdir: #{Path.join(commondir, ".git")}\n")

      for dir <- [commondir, gitfile] do
        started = System.monotonic_time(:millisecond)
        assert SafeGit.repository(dir) == :not_repository
        assert LemonCore.TrustedRoot.resolve(dir) =~ Path.basename(dir)
        assert System.monotonic_time(:millisecond) - started < 3_000
      end
    end

    test "metadata reads refuse FIFOs and devices" do
      base =
        Path.join(System.tmp_dir!(), "lemon-safe-git-meta-#{System.unique_integer([:positive])}")

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)
      fifo = Path.join(base, "fifo")
      {_, 0} = System.cmd("mkfifo", [fifo])

      assert LemonCore.TrustedRoot.read_metadata(fifo) == :error
      assert LemonCore.TrustedRoot.read_metadata("/dev/zero") == :error
      File.write!(Path.join(base, "HEAD"), "ref: refs/heads/main\n")

      assert {:ok, "ref: refs/heads/main\n"} =
               LemonCore.TrustedRoot.read_metadata(Path.join(base, "HEAD"))
    end
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

  defp git!(repo, args, env \\ [], config \\ []) do
    {out, 0} = System.cmd("git", config ++ ["-C", repo | args], stderr_to_stdout: true, env: env)
    out
  end

  defp repo!(dir) do
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir])
    File.write!(Path.join(dir, "tracked.txt"), "one\n")
    git!(dir, ["add", "tracked.txt"])
    commit!(dir, "init")
    dir
  end

  defp commit!(dir, message) do
    git!(dir, [
      "-c",
      "user.name=T",
      "-c",
      "user.email=t@example.invalid",
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "-qm",
      message
    ])
  end

  defp program!(dir, name, marker, tail) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n: > '#{marker}'\n#{tail}\n")
    File.chmod!(path, 0o755)
    path
  end
end
