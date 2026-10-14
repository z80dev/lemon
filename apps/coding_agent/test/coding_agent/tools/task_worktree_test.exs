defmodule CodingAgent.Tools.Task.WorktreeTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task.Worktree

  @moduletag :tmp_dir

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

  test "creates a retained branch and checkout from HEAD, without local state", context do
    %{git: git, repo: repo} = context
    File.write!(Path.join(repo, "tracked.txt"), "uncommitted\n")
    File.write!(Path.join(repo, ".env"), "SECRET=private\n")
    File.write!(Path.join(repo, "untracked.txt"), "private\n")
    File.mkdir_p!(Path.join(repo, ".lemon"))
    File.write!(Path.join(repo, ".lemon/config.toml"), "private = true\n")

    assert {:ok, prepared} = Worktree.prepare(repo, "task_123-abc")
    assert prepared.branch == "lemon/task-task_123-abc"
    assert prepared.worktree_path == Path.join(repo, ".git/lemon-task-worktrees/task_123-abc")
    assert prepared.cwd == prepared.worktree_path
    assert Path.type(prepared.cwd) == :absolute
    assert File.read!(Path.join(prepared.cwd, "tracked.txt")) == "committed\n"
    refute File.exists?(Path.join(prepared.cwd, ".env"))
    refute File.exists?(Path.join(prepared.cwd, ".lemon/config.toml"))
    refute File.exists?(Path.join(prepared.cwd, "untracked.txt"))

    assert git!(git, prepared.cwd, ["rev-parse", "HEAD"]) ==
             git!(git, repo, ["rev-parse", "HEAD"])

    assert git!(git, prepared.cwd, ["branch", "--show-current"]) == prepared.branch
    assert File.read!(Path.join(repo, "tracked.txt")) == "uncommitted\n"

    File.write!(Path.join(prepared.cwd, "review.txt"), "keep for parent\n")
    assert {:error, _} = Worktree.prepare(repo, "task_123-abc")
    assert File.read!(Path.join(prepared.cwd, "review.txt")) == "keep for parent\n"
    assert git!(git, repo, ["show-ref", "--verify", "refs/heads/#{prepared.branch}"]) != ""
  end

  test "preserves the source cwd relative to the repository root", %{git: git, repo: repo} do
    cwd = Path.join(repo, "nested/project")
    assert {:ok, prepared} = Worktree.prepare(cwd, "nested-task")
    assert prepared.cwd == Path.join(prepared.worktree_path, "nested/project")
    assert File.read!(Path.join(prepared.cwd, "source.ex")) == "tracked source\n"
    assert git!(git, prepared.cwd, ["rev-parse", "--show-prefix"]) == "nested/project/"
  end

  test "uses the common Git directory when called from another worktree", %{
    git: git,
    repo: repo,
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "source-worktree")
    git!(git, repo, ["worktree", "add", "-b", "source-branch", source])
    File.write!(Path.join(source, "tracked.txt"), "source branch commit\n")
    git!(git, source, ["add", "tracked.txt"])
    git!(git, source, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Source branch change"])

    assert {:ok, prepared} = Worktree.prepare(Path.join(source, "nested/project"), "linked-task")
    assert prepared.worktree_path == Path.join(repo, ".git/lemon-task-worktrees/linked-task")
    assert prepared.cwd == Path.join(prepared.worktree_path, "nested/project")

    assert git!(git, prepared.cwd, ["rev-parse", "HEAD"]) ==
             git!(git, source, ["rev-parse", "HEAD"])

    assert File.read!(Path.join(prepared.worktree_path, "tracked.txt")) ==
             "source branch commit\n"
  end

  test "rejects a nonrepository and missing cwd clearly", %{tmp_dir: tmp_dir} do
    # ExUnit's tmp_dir is nested in this checkout; block Git's upward discovery.
    File.write!(Path.join(tmp_dir, ".git"), "not a git directory\n")
    assert {:error, message} = Worktree.prepare(tmp_dir, "nonrepo")
    assert message =~ "not a Git working tree"
    assert {:error, message} = Worktree.prepare(Path.join(tmp_dir, "missing"), "missing")
    assert message =~ "not a Git working tree"
  end

  test "rejects unsafe and nongenerated task IDs before creating resources", %{repo: repo} do
    for id <- [
          "",
          ".",
          "..",
          "../escape",
          "a/../../escape",
          "/absolute",
          "a\\b",
          "-option",
          "a.b",
          "space id",
          "a\n",
          "é",
          String.duplicate("a", 129)
        ] do
      assert {:error, message} = Worktree.prepare(repo, id)
      assert message =~ "Invalid worktree task ID"
    end

    assert {:error, _} = Worktree.prepare(repo, nil)
    refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees"))
  end

  test "preserves a preexisting path and does not create its branch", %{git: git, repo: repo} do
    path = Path.join(repo, ".git/lemon-task-worktrees/existing")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "keep"), "original")

    assert {:error, _} = Worktree.prepare(repo, "existing")
    assert File.read!(Path.join(path, "keep")) == "original"
    refute branch_exists?(git, repo, "lemon/task-existing")
  end

  test "preserves a preexisting branch and removes only its new empty path", %{
    git: git,
    repo: repo
  } do
    branch = "lemon/task-existing-branch"
    git!(git, repo, ["branch", branch])
    original = git!(git, repo, ["rev-parse", branch])

    assert {:error, _} = Worktree.prepare(repo, "existing-branch")
    assert git!(git, repo, ["rev-parse", branch]) == original
    refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees/existing-branch"))
  end

  test "rejects preexisting symlinks without touching their targets", %{
    git: git,
    repo: repo,
    tmp_dir: tmp_dir
  } do
    parent = Path.join(repo, ".git/lemon-task-worktrees")
    File.mkdir_p!(parent)
    target = Path.join(tmp_dir, "private")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "keep"), "original")
    File.ln_s!(target, Path.join(parent, "symlink"))

    assert {:error, _} = Worktree.prepare(repo, "symlink")
    assert File.read!(Path.join(target, "keep")) == "original"
    assert {:ok, ^target} = File.read_link(Path.join(parent, "symlink"))
    refute branch_exists?(git, repo, "lemon/task-symlink")
  end

  test "cleans a failed checkout's resources without removing successful siblings", %{
    git: git,
    repo: repo
  } do
    assert {:ok, retained} = Worktree.prepare(repo, "retained")
    File.write!(Path.join(retained.cwd, "keep"), "review")
    cwd = Path.join(repo, "untracked-directory")
    File.mkdir_p!(cwd)

    assert {:error, message} = Worktree.prepare(cwd, "failed")
    assert message =~ "cwd does not exist in the committed Git tree"
    refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees/failed"))
    refute branch_exists?(git, repo, "lemon/task-failed")
    refute git!(git, repo, ["worktree", "list", "--porcelain"]) =~ "refs/heads/lemon/task-failed"
    assert File.read!(Path.join(retained.cwd, "keep")) == "review"
    assert branch_exists?(git, repo, retained.branch)
  end

  test "cleans its reserved path when the repository has no HEAD", %{git: git, tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "unborn")
    File.mkdir_p!(repo)
    git!(git, repo, ["init", "-q", "-b", "main"])

    assert {:error, _} = Worktree.prepare(repo, "unborn-task")
    refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees/unborn-task"))
    refute branch_exists?(git, repo, "lemon/task-unborn-task")
  end

  describe "patch merge mode" do
    test "replays the parent's tracked and untracked work into a baseline commit", context do
      %{git: git, repo: repo, tmp_dir: tmp_dir} = context
      # The baseline commit must not depend on a configured Git identity.
      unset_identity(git, repo)
      outside = Path.join(tmp_dir, "outside.txt")
      File.write!(outside, "outside\n")
      File.write!(Path.join(repo, "tracked.txt"), "uncommitted\n")
      File.write!(Path.join(repo, ".env"), "SECRET=private\n")
      File.mkdir_p!(Path.join(repo, "new/dir"))
      File.write!(Path.join(repo, "new/dir/untracked.sh"), "#!/bin/sh\n")
      File.chmod!(Path.join(repo, "new/dir/untracked.sh"), 0o755)
      File.ln_s!("../../tracked.txt", Path.join(repo, "new/dir/inside-link"))
      File.ln_s!(outside, Path.join(repo, "outside-link"))
      File.ln_s!("../../outside.txt", Path.join(repo, "escaping-link"))

      assert {:ok, prepared} = Worktree.prepare(repo, "wip-task", "patch")
      assert prepared.base_commit == git!(git, repo, ["rev-parse", "HEAD"])
      assert prepared.baseline_commit == git!(git, prepared.cwd, ["rev-parse", "HEAD"])
      refute prepared.baseline_commit == prepared.base_commit

      assert File.read!(Path.join(prepared.cwd, "tracked.txt")) == "uncommitted\n"
      untracked = Path.join(prepared.cwd, "new/dir/untracked.sh")
      assert File.read!(untracked) == "#!/bin/sh\n"
      assert Bitwise.band(File.stat!(untracked).mode, 0o111) != 0

      assert {:ok, "../../tracked.txt"} =
               File.read_link(Path.join(prepared.cwd, "new/dir/inside-link"))

      refute File.exists?(Path.join(prepared.cwd, ".env"))
      assert {:error, _} = File.lstat(Path.join(prepared.cwd, "outside-link"))
      assert {:error, _} = File.lstat(Path.join(prepared.cwd, "escaping-link"))
      assert git!(git, prepared.cwd, ["status", "--porcelain"]) == ""

      # The parent checkout is not modified by preparation.
      assert File.read!(Path.join(repo, "tracked.txt")) == "uncommitted\n"
      assert git!(git, repo, ["status", "--porcelain", "--", "tracked.txt"]) == " M tracked.txt"
      refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees/wip-task.wip.patch"))
    end

    test "applies child edits and commits to the parent, then removes resources", context do
      %{git: git, repo: repo} = context
      File.write!(Path.join(repo, "tracked.txt"), "parent wip\n")
      File.write!(Path.join(repo, "untracked.txt"), "parent untracked\n")
      parent_head = git!(git, repo, ["rev-parse", "HEAD"])

      assert {:ok, prepared} = Worktree.prepare(Path.join(repo, "nested"), "apply-task", "patch")
      path = prepared.worktree_path
      File.write!(Path.join(path, "tracked.txt"), "parent wip\nchild line\n")
      File.write!(Path.join(path, "untracked.txt"), "parent untracked\nchild edit\n")
      File.rm!(Path.join(path, "nested/project/source.ex"))
      File.write!(Path.join(path, "binary.bin"), <<0, 1, 2, 255>>)
      File.write!(Path.join(path, "committed.txt"), "child commit\n")
      git!(git, path, ["add", "committed.txt"])
      git!(git, path, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Child commit"])

      merge = Worktree.finalize(prepared, Path.join(repo, "nested"), "apply-task", "Apply")

      assert merge.mode == "patch"
      assert merge.status == "applied"
      assert merge.files_total == 5

      assert Enum.sort(merge.files) ==
               ~w(binary.bin committed.txt nested/project/source.ex tracked.txt untracked.txt)

      assert File.read!(Path.join(repo, "tracked.txt")) == "parent wip\nchild line\n"
      assert File.read!(Path.join(repo, "untracked.txt")) == "parent untracked\nchild edit\n"
      assert File.read!(Path.join(repo, "committed.txt")) == "child commit\n"
      assert File.read!(Path.join(repo, "binary.bin")) == <<0, 1, 2, 255>>
      refute File.exists?(Path.join(repo, "nested/project/source.ex"))
      # Applied to the working tree only: HEAD and the index are untouched.
      assert git!(git, repo, ["rev-parse", "HEAD"]) == parent_head
      assert git!(git, repo, ["diff", "--cached", "--name-only"]) == ""

      refute File.exists?(path)
      refute File.exists?(Path.join(repo, ".git/lemon-task-worktrees/apply-task.patch"))
      refute branch_exists?(git, repo, prepared.branch)
    end

    test "fails closed on conflicts, keeping the parent, worktree, branch and patch", context do
      %{git: git, repo: repo} = context
      assert {:ok, prepared} = Worktree.prepare(repo, "conflict-task", "patch")
      File.write!(Path.join(prepared.worktree_path, "tracked.txt"), "child version\n")
      File.write!(Path.join(prepared.worktree_path, "other.txt"), "child other\n")
      File.write!(Path.join(repo, "tracked.txt"), "parent changed later\n")

      merge = Worktree.finalize(prepared, repo, "conflict-task", "Conflict")

      assert merge.status == "conflict"
      assert merge.conflicting_files == ["tracked.txt"]
      assert merge.patch_path == Path.join(repo, ".git/lemon-task-worktrees/conflict-task.patch")
      assert File.read!(merge.patch_path) =~ "child version"
      assert merge.worktree_path == prepared.worktree_path
      assert File.read!(Path.join(repo, "tracked.txt")) == "parent changed later\n"
      refute File.exists?(Path.join(repo, "other.txt"))
      assert File.read!(Path.join(prepared.worktree_path, "tracked.txt")) == "child version\n"
      assert branch_exists?(git, repo, prepared.branch)
      assert Worktree.summary(merge) =~ merge.patch_path

      # The retained patch can be applied once the parent conflict is resolved.
      File.write!(Path.join(repo, "tracked.txt"), "committed\n")
      git!(git, repo, ["apply", merge.patch_path])
      assert File.read!(Path.join(repo, "tracked.txt")) == "child version\n"
    end

    test "removes the worktree and branch when the child changed nothing", context do
      %{git: git, repo: repo} = context
      File.write!(Path.join(repo, "tracked.txt"), "parent wip\n")
      assert {:ok, prepared} = Worktree.prepare(repo, "idle-task", "patch")

      assert %{mode: "patch", status: "no_changes"} =
               merge = Worktree.finalize(prepared, repo, "idle-task", "Idle")

      refute Map.has_key?(merge, :cleanup_error)
      refute File.exists?(prepared.worktree_path)
      refute branch_exists?(git, repo, prepared.branch)
      assert File.read!(Path.join(repo, "tracked.txt")) == "parent wip\n"
    end
  end

  describe "branch merge mode" do
    test "commits child work on the kept branch without touching the parent", context do
      %{git: git, repo: repo} = context
      unset_identity(git, repo)
      File.write!(Path.join(repo, "tracked.txt"), "parent wip\n")
      parent_head = git!(git, repo, ["rev-parse", "HEAD"])

      assert {:ok, prepared} = Worktree.prepare(repo, "branch-task", "branch")
      # Branch mode does not replay the parent's uncommitted work.
      assert File.read!(Path.join(prepared.cwd, "tracked.txt")) == "committed\n"
      File.write!(Path.join(prepared.cwd, "feature.txt"), "child work\n")

      merge =
        Worktree.finalize(prepared, repo, "branch-task", "Add feature\nwith details")

      assert merge.status == "committed"
      assert merge.commits == 1
      assert merge.head == git!(git, repo, ["rev-parse", prepared.branch])

      assert git!(git, repo, ["show", "#{prepared.branch}:feature.txt"]) == "child work"
      refute File.exists?(prepared.worktree_path)
      assert git!(git, repo, ["rev-parse", "HEAD"]) == parent_head
      refute File.exists?(Path.join(repo, "feature.txt"))
      assert File.read!(Path.join(repo, "tracked.txt")) == "parent wip\n"
    end

    test "reports a child's own commits even with nothing left to stage", context do
      %{git: git, repo: repo} = context
      assert {:ok, prepared} = Worktree.prepare(repo, "child-commit", "branch")
      File.write!(Path.join(prepared.cwd, "own.txt"), "own\n")
      git!(git, prepared.cwd, ["add", "own.txt"])
      git!(git, prepared.cwd, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Own commit"])

      assert %{status: "committed", commits: 1} =
               Worktree.finalize(prepared, repo, "child-commit", "Own")

      assert git!(git, repo, ["log", "-1", "--format=%s", prepared.branch]) == "Own commit"
    end
  end

  # useConfigOnly stops Git from inventing an identity from the host name.
  defp unset_identity(git, repo) do
    git!(git, repo, ["config", "--unset", "user.name"])
    git!(git, repo, ["config", "--unset", "user.email"])
    git!(git, repo, ["config", "user.useConfigOnly", "true"])
  end

  defp branch_exists?(git, cwd, branch) do
    {_output, status} =
      System.cmd(git, ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
        cd: cwd,
        stderr_to_stdout: true
      )

    status == 0
  end

  defp git!(git, cwd, args) do
    {output, status} = System.cmd(git, args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, "Git command failed: #{inspect(args)}: #{output}"
    String.trim_trailing(output, "\n")
  end
end
