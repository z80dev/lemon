defmodule LemonCore.AutomaticGitSafetyTest do
  # The support bundle reads a project repository's build info. Its
  # configuration must not make those reads run programs.
  use ExUnit.Case, async: false

  alias LemonCore.BuildInfo

  @moduletag :tmp_dir

  test "support-bundle build info runs no fsmonitor program or clean filter", %{tmp_dir: tmp} do
    repo = repo!(Path.join(tmp, "repo"))
    marker = Path.join(tmp, "program-ran")
    git!(repo, ["config", "core.fsmonitor", program!(tmp, "fsmonitor", marker, "exit 1")])
    git!(repo, ["config", "filter.evil.clean", program!(tmp, "clean", marker, "cat")])
    File.write!(Path.join(repo, ".git/info/attributes"), "* filter=evil\n")
    File.touch!(Path.join(repo, "tracked.txt"), {{2020, 1, 1}, {0, 0, 0}})

    info = with_env("RELEASE_NAME", nil, fn -> BuildInfo.current(cwd: repo) end)

    assert info.git.branch == "main"
    assert info.git.dirty? == false
    refute File.exists?(marker), "build info ran a program named by repository config"
  end

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    try do
      fun.()
    after
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    out
  end

  defp repo!(dir) do
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir])
    File.write!(Path.join(dir, "tracked.txt"), "one\n")
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

    dir
  end

  defp program!(dir, name, marker, tail) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n: > '#{marker}'\n#{tail}\n")
    File.chmod!(path, 0o755)
    path
  end
end
