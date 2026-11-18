defmodule LemonOmp.SessionDiscoveryGitSafetyTest do
  # `omp.sessions.discover` needs only read scope, and its kept-worktree
  # inventory reads the workspace repository. That repository's configuration
  # (signature display with a chosen gpg.program, fsmonitor) must not make
  # listing sessions run a program.
  use ExUnit.Case, async: false

  alias LemonOmp.SessionFiles

  @moduletag :tmp_dir

  test "session discovery runs no gpg.program or fsmonitor named by the repository", %{
    tmp_dir: tmp
  } do
    repo = Path.join(System.tmp_dir!(), "lemon-omp-gpg-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(repo) end)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    commit!(repo, [])

    # A kept Lemon worktree whose branch holds a signed commit.
    path = Path.join(repo, ".git/lemon-omp-worktrees/omp_signed")
    git!(repo, ["branch", "lemon-omp/omp_signed"])
    git!(repo, ["worktree", "add", "-q", path, "lemon-omp/omp_signed"])
    signer = program!(tmp, "signer", Path.join(tmp, "signer-ran"), fake_gpg_sign())
    commit!(path, ["-c", "gpg.program=#{signer}", "-c", "commit.gpgSign=true"])
    assert git!(path, ["cat-file", "commit", "HEAD"]) =~ "gpgsig"

    marker = Path.join(tmp, "program-ran")
    git!(repo, ["config", "log.showSignature", "true"])
    git!(repo, ["config", "gpg.program", program!(tmp, "gpg", marker, "exit 1")])
    git!(repo, ["config", "core.fsmonitor", program!(tmp, "fsmonitor", marker, "exit 1")])

    assert {:ok, _sessions} =
             SessionFiles.discover(repo, sessions_dir: Path.join(tmp, "none"), session_dir: nil)

    assert [%{branch: "lemon-omp/omp_signed", base: base}] = LemonOmp.Worktree.kept(repo)
    assert is_binary(base)
    refute File.exists?(marker), "session discovery ran a program named by repository config"
  end

  # `git commit -S` accepts a signature once the status stream reports it.
  defp fake_gpg_sign do
    """
    printf '\\n[GNUPG:] SIG_CREATED D 1 8 00 0 0\\n' >&2
    printf -- '-----BEGIN PGP SIGNATURE-----\\n\\nAAAA\\n-----END PGP SIGNATURE-----\\n'
    """
  end

  defp commit!(dir, config) do
    git!(
      dir,
      config ++
        [
          "-c",
          "user.name=T",
          "-c",
          "user.email=t@example.invalid",
          "-c",
          "core.hooksPath=/dev/null",
          "commit",
          "-q",
          "--allow-empty",
          "-m",
          "commit"
        ]
    )
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp program!(dir, name, marker, tail) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n: > '#{marker}'\n#{tail}\n")
    File.chmod!(path, 0o755)
    path
  end
end
