defmodule CodingAgent.Tools.Task.WorktreeCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  using do
    quote do
      alias CodingAgent.Tools.Task.Worktree
      import CodingAgent.Tools.Task.WorktreeCase
      @moduletag :tmp_dir
    end
  end

  setup %{tmp_dir: tmp_dir} do
    git = System.find_executable("git") || raise "Git is required for worktree tests"
    repo = Path.join(tmp_dir, "repository")
    File.mkdir_p!(Path.join(repo, "nested/project"))
    git!(git, repo, ["init", "-q", "-b", "main"])
    git!(git, repo, ["config", "user.name", "Worktree Test"])
    git!(git, repo, ["config", "user.email", "worktree@example.invalid"])
    repo = git!(git, repo, ["rev-parse", "--show-toplevel"])
    File.write!(Path.join(repo, "tracked.txt"), "committed\n")
    File.write!(Path.join(repo, "nested/project/source.ex"), "tracked source\n")
    File.write!(Path.join(repo, ".gitignore"), ".env\n.lemon/\n")
    git!(git, repo, ["add", "."])
    git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Initial tree"])
    %{git: git, repo: repo}
  end

  def local_submodule(git, repo, tmp_dir) do
    source = Path.join(tmp_dir, "vendor-source")
    File.mkdir_p!(source)
    git!(git, source, ["init", "-q", "-b", "main"])
    git!(git, source, ["config", "user.name", "Worktree Test"])
    git!(git, source, ["config", "user.email", "worktree@example.invalid"])
    File.write!(Path.join(source, "version.txt"), "original\n")
    git!(git, source, ["add", "."])
    git!(git, source, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Original vendor"])
    old_pin = git!(git, source, ["rev-parse", "HEAD"])

    git!(git, repo, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "--",
      source,
      "vendor"
    ])

    git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Pin local vendor"])
    # The explicit detector must override both repository and submodule filters.
    git!(git, repo, ["config", "diff.ignoreSubmodules", "all"])
    git!(git, repo, ["config", "submodule.vendor.ignore", "all"])
    File.write!(Path.join(source, "version.txt"), "updated\n")
    git!(git, source, ["add", "."])
    git!(git, source, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Update vendor"])
    %{source: source, old_pin: old_pin, new_pin: git!(git, source, ["rev-parse", "HEAD"])}
  end

  # Committed `.gitmodules` filters are what `git add` honours for gitlinks.
  def ignore_all_in_gitmodules(git, repo) do
    git!(git, repo, ["config", "--file", ".gitmodules", "submodule.vendor.ignore", "all"])
    git!(git, repo, ["add", ".gitmodules"])
    git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Ignore vendor checkout"])
  end

  def init_child_submodule(git, cwd) do
    git!(git, cwd, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "update",
      "--init",
      "-q",
      "--",
      "vendor"
    ])

    Path.join(cwd, "vendor")
  end

  def change_gitlink(git, cwd, "pin", pin),
    do: git!(git, cwd, ["update-index", "--cacheinfo", "160000,#{pin},vendor"])

  def change_gitlink(git, cwd, "addition", pin) do
    path = "new vendor\tpin"
    File.mkdir_p!(Path.join(cwd, path))
    git!(git, cwd, ["update-index", "--add", "--cacheinfo", "160000,#{pin},#{path}"])
  end

  def change_gitlink(git, cwd, "deletion", _pin),
    do: git!(git, cwd, ["rm", "-f", "--", "vendor"])

  def change_gitlink(git, cwd, "replacement", _pin) do
    File.rm_rf!(Path.join(cwd, "vendor"))
    File.write!(Path.join(cwd, "vendor"), "ordinary file replacing a gitlink\n")
    git!(git, cwd, ["add", "--", "vendor"])
  end

  def checkout_snapshot(git, cwd) do
    %{
      head: git!(git, cwd, ["rev-parse", "HEAD"]),
      index: git!(git, cwd, ["write-tree"]),
      staged:
        git!(git, cwd, [
          "diff",
          "--cached",
          "--binary",
          "--no-ext-diff",
          "--ignore-submodules=none",
          "HEAD"
        ]),
      unstaged:
        git!(git, cwd, [
          "diff",
          "--binary",
          "--no-ext-diff",
          "--ignore-submodules=none"
        ]),
      status: git!(git, cwd, ["status", "--porcelain=v1", "-z", "--ignore-submodules=none"])
    }
  end

  # useConfigOnly stops Git from inventing an identity from the host name.
  def unset_identity(git, repo) do
    git!(git, repo, ["config", "--unset", "user.name"])
    git!(git, repo, ["config", "--unset", "user.email"])
    git!(git, repo, ["config", "user.useConfigOnly", "true"])
  end

  def branch_exists?(git, cwd, branch) do
    {_output, status} =
      System.cmd(git, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
        cd: cwd,
        env: git_env(),
        stderr_to_stdout: true
      )

    status == 0
  end

  def git!(git, cwd, args) do
    {output, status} = System.cmd(git, args, cd: cwd, env: git_env(), stderr_to_stdout: true)
    assert status == 0, "Git command failed: #{inspect(args)}: #{output}"
    String.trim_trailing(output, "\n")
  end

  defp git_env do
    [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]
  end
end
