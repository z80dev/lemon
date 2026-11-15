Code.require_file("../../support/task_worktree_case.ex", __DIR__)

defmodule CodingAgent.Tools.Task.CowCloneTest do
  use CodingAgent.Tools.Task.WorktreeCase, async: false

  setup do
    keys = [:task_clone_probe, :task_workspace_backend, :task_clone_directories]
    original = Enum.map(keys, &{&1, Application.fetch_env(:coding_agent, &1)})
    Enum.each(keys, &Application.delete_env(:coding_agent, &1))

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:coding_agent, key, value)
        {key, :error} -> Application.delete_env(:coding_agent, key)
      end)
    end)

    :ok
  end

  test "unsupported CoW probe selects the clean Git fallback", %{repo: repo} do
    Application.put_env(:coding_agent, :task_clone_probe, fn -> false end)
    File.write!(Path.join(repo, ".env"), "ignored artifact\n")
    assert {:ok, prepared} = Worktree.prepare(repo, "unsupported", "patch")
    assert prepared.backend == :git_worktree
    refute File.exists?(Path.join(prepared.cwd, ".env"))
    assert %{status: "no_changes"} = Worktree.finalize(prepared, repo, "unsupported", "")
    refute File.exists?(prepared.worktree_path)
  end

  test "operator can force the Git backend", %{repo: repo} do
    Application.put_env(:coding_agent, :task_workspace_backend, :git_worktree)
    Application.put_env(:coding_agent, :task_clone_probe, fn -> flunk("probe must not run") end)
    assert {:ok, prepared} = Worktree.prepare(repo, "forced", "patch")
    assert prepared.backend == :git_worktree
    assert %{status: "no_changes"} = Worktree.finalize(prepared, repo, "forced", "")
  end

  test "oversized cache falls back without copying artifacts", %{git: git, repo: repo} do
    Application.put_env(:coding_agent, :task_clone_probe, fn -> true end)
    File.write!(Path.join(repo, ".gitignore"), "_build/\n")
    git!(git, repo, ["add", ".gitignore"])
    git!(git, repo, ["commit", "-qm", "Ignore build cache"])
    File.mkdir_p!(Path.join(repo, "_build"))
    huge = Path.join([repo, "_build", "sparse"])
    {:ok, file} = :file.open(String.to_charlist(huge), [:write, :raw, :binary])

    try do
      {:ok, _} = :file.position(file, 64 * 1024 * 1024 * 1024 + 1)
      :ok = :file.truncate(file)
    after
      :file.close(file)
    end

    assert {:ok, prepared} = Worktree.prepare(repo, "oversized", "patch")
    assert prepared.backend == :git_worktree
    refute File.exists?(Path.join(prepared.cwd, "_build"))
    assert %{status: "no_changes"} = Worktree.finalize(prepared, repo, "oversized", "")
  end

  @tag skip: :os.type() != {:unix, :darwin}
  test "ignored symlinks are not followed", %{repo: repo, tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "outside"), "private\n")
    File.ln_s!(Path.join(tmp_dir, "outside"), Path.join(repo, ".env"))
    assert {:ok, prepared} = Worktree.prepare(repo, "symlink", "patch")
    assert prepared.backend == :cow
    refute File.exists?(Path.join(prepared.cwd, ".env"))
    assert %{status: "no_changes"} = Worktree.finalize(prepared, repo, "symlink", "")
    refute File.exists?(prepared.worktree_path)
  end

  @tag skip: :os.type() != {:unix, :darwin}
  test "every merge mode warms only ignored allowlisted directories", %{git: git, repo: repo} do
    File.write!(Path.join(repo, ".gitignore"), ".env\n_build/\ncustom-cache/\n")
    git!(git, repo, ["add", ".gitignore"])
    git!(git, repo, ["commit", "-qm", "Ignore caches"])
    File.write!(Path.join(repo, ".env"), "secret\n")

    for directory <- ["_build", "custom-cache", "target"] do
      File.mkdir_p!(Path.join(repo, directory))
      File.write!(Path.join([repo, directory, "artifact"]), "warm\n")
    end

    for mode <- ["none", "branch", "patch"] do
      assert {:ok, prepared} = Worktree.prepare(repo, "privacy-#{mode}", mode)
      assert prepared.backend == :cow
      assert File.read!(Path.join([prepared.cwd, "_build", "artifact"])) == "warm\n"
      refute File.exists?(Path.join(prepared.cwd, ".env"))
      refute File.exists?(Path.join(prepared.cwd, "custom-cache"))
      # Non-ignored target is parent WIP, replayed only in patch mode.
      assert File.exists?(Path.join(prepared.cwd, "target")) == (mode == "patch")
    end

    Application.put_env(:coding_agent, :task_clone_directories, ["custom-cache"])
    assert {:ok, prepared} = Worktree.prepare(repo, "custom", "branch")
    assert File.read!(Path.join([prepared.cwd, "custom-cache", "artifact"])) == "warm\n"
    refute File.exists?(Path.join(prepared.cwd, "_build"))
  end

  @tag skip: :os.type() != {:unix, :darwin}
  test "APFS clones ignored artifacts without patch noise and cleans up", %{git: git, repo: repo} do
    File.write!(Path.join(repo, ".gitignore"), "deps/\n_build/\nnode_modules/\n")
    git!(git, repo, ["add", ".gitignore"])
    git!(git, repo, ["commit", "-qm", "Ignore build artifacts"])

    for directory <- ["deps", "_build", "node_modules"] do
      File.mkdir_p!(Path.join(repo, directory))
      File.write!(Path.join([repo, directory, "artifact"]), "warm\n")
    end

    File.write!(Path.join(repo, "tracked.txt"), "parent WIP\n")
    assert {:ok, prepared} = Worktree.prepare(repo, "warm", "patch")
    assert prepared.backend == :cow

    for directory <- ["deps", "_build", "node_modules"] do
      artifact = Path.join([prepared.cwd, directory, "artifact"])
      assert File.read!(artifact) == "warm\n"
      File.write!(artifact, "child build\n")
    end

    File.write!(Path.join(prepared.cwd, "tracked.txt"), "child edit\n")
    assert %{status: "applied", files_total: 1} = Worktree.finalize(prepared, repo, "warm", "")
    assert File.read!(Path.join(repo, "tracked.txt")) == "child edit\n"
    assert File.read!(Path.join([repo, "deps", "artifact"])) == "warm\n"
    refute File.exists?(prepared.worktree_path)
  end
end
