defmodule LemonCore.TrustedRootTest do
  use ExUnit.Case, async: true

  alias LemonCore.TrustedRoot

  # Outside every Git checkout so a parent repository cannot mask the cases.
  setup do
    base =
      Path.join(System.tmp_dir!(), "lemon-core-trusted-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    {:ok, base} = TrustedRoot.realpath(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp repo!(dir) do
    File.mkdir_p!(Path.join(dir, ".git/objects"))
    File.mkdir_p!(Path.join(dir, ".git/refs"))
    File.write!(Path.join(dir, ".git/HEAD"), "ref: refs/heads/main\n")
    dir
  end

  test "an empty .git directory or file in a parent never widens the root", %{base: base} do
    cwd = Path.join(base, "parent/session")
    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(base, "parent/.git"))
    assert TrustedRoot.resolve(cwd) == cwd

    File.rm_rf!(Path.join(base, "parent/.git"))
    File.write!(Path.join(base, "parent/.git"), "")
    assert TrustedRoot.resolve(cwd) == cwd

    File.write!(Path.join(base, "parent/.git"), "gitdir: #{Path.join(base, "nowhere")}\n")
    assert TrustedRoot.resolve(cwd) == cwd
  end

  test "a real repository, gitfile or linked worktree sets the root", %{base: base} do
    repo = repo!(Path.join(base, "repo"))
    nested = Path.join(repo, "a/b")
    File.mkdir_p!(nested)
    assert TrustedRoot.resolve(nested) == repo

    # Submodule-style gitfile pointing at a real git directory.
    sub = Path.join(base, "sub")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, ".git"), "gitdir: #{Path.join(repo, ".git")}\n")
    assert TrustedRoot.resolve(sub) == sub

    # Linked worktree: gitdir holds HEAD and a commondir naming the store.
    worktree_gitdir = Path.join(repo, ".git/worktrees/wt")
    File.mkdir_p!(worktree_gitdir)
    File.write!(Path.join(worktree_gitdir, "HEAD"), "ref: refs/heads/wt\n")
    File.write!(Path.join(worktree_gitdir, "commondir"), "../..\n")
    wt = Path.join(base, "wt")
    File.mkdir_p!(Path.join(wt, "x"))
    File.write!(Path.join(wt, ".git"), "gitdir: #{worktree_gitdir}\n")
    assert TrustedRoot.resolve(Path.join(wt, "x")) == wt
  end

  test "read/3 refuses links leaving the root and hard links", %{base: base} do
    repo = repo!(Path.join(base, "repo"))
    secret = Path.join(base, "secret")
    File.write!(secret, "SECRET")
    File.ln_s!(secret, Path.join(repo, "link.md"))
    File.ln!(secret, Path.join(repo, "hard.md"))
    File.write!(Path.join(repo, "ok.md"), "OK")

    assert TrustedRoot.read(Path.join(repo, "link.md"), repo) == :error
    assert TrustedRoot.read(Path.join(repo, "hard.md"), repo) == :error
    assert {:ok, "OK", _} = TrustedRoot.read(Path.join(repo, "ok.md"), repo)
    assert TrustedRoot.read(Path.join(repo, "ok.md"), repo, max_bytes: 1) == :error
  end
end
