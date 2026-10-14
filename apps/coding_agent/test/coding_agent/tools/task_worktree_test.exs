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

  test "merge-back targets the linked parent checkout, not the common repository checkout", %{
    git: git,
    repo: repo,
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(repo, "tracked.txt"), "main checkout work\n")
    git!(git, repo, ["add", "tracked.txt"])
    main_head = git!(git, repo, ["rev-parse", "HEAD"])
    main_index = git!(git, repo, ["diff", "--cached"])

    for mode <- ["patch", "branch"] do
      source = Path.join(tmp_dir, "source-#{mode}")
      git!(git, repo, ["worktree", "add", "-b", "source-#{mode}", source])
      File.write!(Path.join(source, "tracked.txt"), "linked parent work\n")
      id = "linked-#{mode}"
      assert {:ok, prepared} = Worktree.prepare(source, id, mode)
      File.write!(Path.join(prepared.cwd, "tracked.txt"), "child work\n")

      merge = Worktree.finalize(prepared, source, id, "Linked child")
      assert merge.status == if(mode == "patch", do: "applied", else: "committed")
      expected = if mode == "patch", do: "child work\n", else: "linked parent work\n"
      assert File.read!(Path.join(source, "tracked.txt")) == expected
      assert git!(git, source, ["rev-parse", "HEAD"]) == main_head
      assert git!(git, source, ["diff", "--cached"]) == ""
      assert File.read!(Path.join(repo, "tracked.txt")) == "main checkout work\n"
      assert git!(git, repo, ["rev-parse", "HEAD"]) == main_head
      assert git!(git, repo, ["diff", "--cached"]) == main_index
    end
  end

  test "cancelled tasks retain their worktree without mutating either checkout", %{
    git: git,
    repo: repo
  } do
    for mode <- ["patch", "branch"] do
      id = "cancelled-#{mode}"
      assert {:ok, prepared} = Worktree.prepare(repo, id, mode)
      File.write!(Path.join(prepared.cwd, "tracked.txt"), "child changes\n")
      child_head = git!(git, prepared.cwd, ["rev-parse", "HEAD"])
      signal = LemonAgent.AbortSignal.new()
      LemonAgent.AbortSignal.abort(signal)

      assert %{status: "skipped"} = Worktree.finalize(prepared, repo, id, "Cancelled", signal)
      assert File.read!(Path.join(repo, "tracked.txt")) == "committed\n"
      assert File.read!(Path.join(prepared.cwd, "tracked.txt")) == "child changes\n"
      assert git!(git, prepared.cwd, ["rev-parse", "HEAD"]) == child_head
      assert branch_exists?(git, repo, prepared.branch)
    end
  end

  test "branch finalization retains commits made after detaching from the task branch", %{
    git: git,
    repo: repo
  } do
    assert {:ok, prepared} = Worktree.prepare(repo, "detached-task", "branch")
    git!(git, prepared.cwd, ["checkout", "--detach", "-q"])
    File.write!(Path.join(prepared.cwd, "detached.txt"), "keep this work\n")
    git!(git, prepared.cwd, ["add", "detached.txt"])
    git!(git, prepared.cwd, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Detached work"])
    head = git!(git, prepared.cwd, ["rev-parse", "HEAD"])

    assert %{status: "error"} = Worktree.finalize(prepared, repo, "detached-task", "Detached")
    assert git!(git, prepared.cwd, ["rev-parse", "HEAD"]) == head
    assert File.read!(Path.join(prepared.cwd, "detached.txt")) == "keep this work\n"
    assert branch_exists?(git, repo, prepared.branch)
    refute File.exists?(Path.join(repo, "detached.txt"))
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

    test "retains submodule pin changes instead of deleting them as no changes", %{
      git: git,
      repo: repo
    } do
      vendor = Path.join(repo, "vendor")
      File.mkdir_p!(vendor)
      git!(git, vendor, ["init", "-q", "-b", "main"])
      git!(git, vendor, ["config", "user.name", "Worktree Test"])
      git!(git, vendor, ["config", "user.email", "worktree@example.invalid"])
      File.write!(Path.join(vendor, "version.txt"), "original\n")
      git!(git, vendor, ["add", "."])
      git!(git, vendor, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Original vendor"])
      git!(git, repo, ["add", "vendor"])
      git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Pin vendor"])
      parent_head = git!(git, repo, ["rev-parse", "HEAD"])
      assert {:ok, prepared} = Worktree.prepare(repo, "submodule-task", "patch")
      child_vendor = Path.join(prepared.cwd, "vendor")
      git!(git, prepared.cwd, ["clone", "--no-hardlinks", vendor, child_vendor])
      git!(git, child_vendor, ["config", "user.name", "Worktree Test"])
      git!(git, child_vendor, ["config", "user.email", "worktree@example.invalid"])
      File.write!(Path.join(child_vendor, "version.txt"), "updated\n")
      git!(git, child_vendor, ["add", "."])

      git!(git, child_vendor, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Update vendor"])

      assert %{status: "error"} = Worktree.finalize(prepared, repo, "submodule-task", "Vendor")
      assert branch_exists?(git, repo, prepared.branch)
      assert File.read!(Path.join(child_vendor, "version.txt")) == "updated\n"
      assert File.read!(Path.join(vendor, "version.txt")) == "original\n"
      assert git!(git, repo, ["rev-parse", "HEAD"]) == parent_head
      assert git!(git, repo, ["status", "--porcelain"]) == ""
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

  for mode <- ["patch", "branch"],
      state <- ["staged", "committed"],
      change <- ["pin", "addition", "deletion", "replacement"] do
    test "#{mode} retains #{state} gitlink #{change} and the parent's exact checkout", context do
      %{git: git, repo: repo, tmp_dir: tmp_dir} = context
      mode = unquote(mode)
      state = unquote(state)
      change = unquote(change)
      %{new_pin: new_pin} = local_submodule(git, repo, tmp_dir)

      File.write!(Path.join(repo, "tracked.txt"), "parent staged\n")
      git!(git, repo, ["add", "tracked.txt"])
      File.write!(Path.join(repo, "tracked.txt"), "parent unstaged\n")
      File.write!(Path.join(repo, "private.txt"), "parent untracked\n")
      vendor = Path.join(repo, "vendor")
      File.write!(Path.join(vendor, "local.txt"), "parent vendor staged\n")
      git!(git, vendor, ["add", "local.txt"])
      File.write!(Path.join(vendor, "version.txt"), "parent vendor unstaged\n")
      parent = checkout_snapshot(git, repo)
      parent_vendor = checkout_snapshot(git, Path.join(repo, "vendor"))
      id = "#{mode}-#{state}-#{change}"
      assert {:ok, prepared} = Worktree.prepare(repo, id, mode)
      # The child submodule is intentionally uninitialized. Only the index pin
      # changes, so an ignore-submodules=all inventory cannot see this work.
      refute File.exists?(Path.join(prepared.cwd, "vendor/.git"))
      change_gitlink(git, prepared.cwd, change, new_pin)

      if state == "committed" do
        git!(git, prepared.cwd, [
          "-c",
          "core.hooksPath=/dev/null",
          "commit",
          "-qm",
          "Child gitlink change"
        ])
      end

      child_head = git!(git, prepared.cwd, ["rev-parse", "HEAD"])
      child_tree = git!(git, prepared.cwd, ["write-tree"])
      child_index = git!(git, prepared.cwd, ["ls-files", "--stage", "-z"])
      merge = Worktree.finalize(prepared, repo, id, "Keep gitlink work")

      assert %{mode: ^mode, status: "error"} = merge
      assert File.dir?(prepared.worktree_path)
      assert branch_exists?(git, repo, prepared.branch)
      assert git!(git, prepared.cwd, ["symbolic-ref", "--short", "HEAD"]) == prepared.branch
      assert git!(git, repo, ["rev-parse", prepared.branch]) == child_head
      assert git!(git, prepared.cwd, ["write-tree"]) == child_tree
      assert git!(git, prepared.cwd, ["ls-files", "--stage", "-z"]) == child_index
      assert checkout_snapshot(git, repo) == parent
      assert checkout_snapshot(git, Path.join(repo, "vendor")) == parent_vendor
      assert File.read!(Path.join(repo, "tracked.txt")) == "parent unstaged\n"
      assert File.read!(Path.join(repo, "private.txt")) == "parent untracked\n"
      assert File.read!(Path.join(repo, "vendor/version.txt")) == "parent vendor unstaged\n"

      if change == "pin" do
        assert git!(git, prepared.cwd, ["rev-parse", ":vendor"]) == new_pin

        if state == "committed" do
          assert git!(git, repo, ["rev-parse", "#{prepared.branch}:vendor"]) == new_pin
        else
          assert git!(git, prepared.cwd, [
                   "diff",
                   "--cached",
                   "--name-only",
                   "--ignore-submodules=none",
                   "HEAD"
                 ]) == "vendor"
        end
      end
    end
  end

  for mode <- ["patch", "branch"] do
    test "#{mode} does not overwrite a staged pin with the initialized checkout's old pin",
         %{git: git, repo: repo, tmp_dir: tmp_dir} do
      mode = unquote(mode)
      %{source: source, new_pin: new_pin, old_pin: old_pin} = local_submodule(git, repo, tmp_dir)
      id = "#{mode}-initialized-pin"
      assert {:ok, prepared} = Worktree.prepare(repo, id, mode)
      child_vendor = Path.join(prepared.cwd, "vendor")
      git!(git, prepared.cwd, ["clone", "--no-hardlinks", source, child_vendor])
      git!(git, child_vendor, ["checkout", "--detach", old_pin])
      git!(git, prepared.cwd, ["update-index", "--cacheinfo", "160000,#{new_pin},vendor"])
      child_tree = git!(git, prepared.cwd, ["write-tree"])

      assert %{status: "error"} = Worktree.finalize(prepared, repo, id, "Staged pin")
      assert git!(git, prepared.cwd, ["write-tree"]) == child_tree
      assert git!(git, prepared.cwd, ["rev-parse", ":vendor"]) == new_pin
      assert git!(git, child_vendor, ["rev-parse", "HEAD"]) == old_pin
      assert branch_exists?(git, repo, prepared.branch)
    end

    test "#{mode} still cleans a genuinely empty child with an unchanged submodule",
         %{git: git, repo: repo, tmp_dir: tmp_dir} do
      mode = unquote(mode)
      local_submodule(git, repo, tmp_dir)
      parent = checkout_snapshot(git, repo)
      id = "#{mode}-idle-vendor"
      assert {:ok, prepared} = Worktree.prepare(repo, id, mode)

      assert %{mode: ^mode, status: "no_changes"} =
               Worktree.finalize(prepared, repo, id, "Idle")

      refute File.exists?(prepared.worktree_path)
      refute branch_exists?(git, repo, prepared.branch)
      assert checkout_snapshot(git, repo) == parent
      assert File.read!(Path.join(repo, "vendor/version.txt")) == "original\n"
    end
  end

  test "branch retains a committed pin and its staged reversal to the original baseline",
       %{git: git, repo: repo, tmp_dir: tmp_dir} do
    %{new_pin: new_pin, old_pin: old_pin} = local_submodule(git, repo, tmp_dir)
    assert {:ok, prepared} = Worktree.prepare(repo, "reversed-pin", "branch")
    change_gitlink(git, prepared.cwd, "pin", new_pin)

    git!(git, prepared.cwd, [
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "-qm",
      "Committed pin"
    ])

    head = git!(git, prepared.cwd, ["rev-parse", "HEAD"])
    change_gitlink(git, prepared.cwd, "pin", old_pin)
    tree = git!(git, prepared.cwd, ["write-tree"])

    assert %{status: "error"} = Worktree.finalize(prepared, repo, "reversed-pin", "Keep reversal")
    assert File.dir?(prepared.worktree_path)
    assert git!(git, repo, ["rev-parse", prepared.branch]) == head
    assert git!(git, repo, ["rev-parse", "#{prepared.branch}:vendor"]) == new_pin
    assert git!(git, prepared.cwd, ["write-tree"]) == tree
    assert git!(git, prepared.cwd, ["rev-parse", ":vendor"]) == old_pin
  end

  defp local_submodule(git, repo, tmp_dir) do
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

  defp change_gitlink(git, cwd, "pin", pin),
    do: git!(git, cwd, ["update-index", "--cacheinfo", "160000,#{pin},vendor"])

  defp change_gitlink(git, cwd, "addition", pin) do
    path = "new vendor\tpin"
    File.mkdir_p!(Path.join(cwd, path))
    git!(git, cwd, ["update-index", "--add", "--cacheinfo", "160000,#{pin},#{path}"])
  end

  defp change_gitlink(git, cwd, "deletion", _pin),
    do: git!(git, cwd, ["rm", "-f", "--", "vendor"])

  defp change_gitlink(git, cwd, "replacement", _pin) do
    File.rm_rf!(Path.join(cwd, "vendor"))
    File.write!(Path.join(cwd, "vendor"), "ordinary file replacing a gitlink\n")
    git!(git, cwd, ["add", "--", "vendor"])
  end

  defp checkout_snapshot(git, cwd) do
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
