defmodule LemonControlPlane.Methods.SessionsChangesGitSafetyTest do
  # `sessions.changes` reads a workspace repository the operator did not
  # necessarily create; its configuration must not make the read run programs.
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.SessionsChanges

  @key "agent:default:web:local:dm:changes-safety"
  @operator_ctx %{auth: %{role: :operator, scopes: [:read, :content]}}

  setup do
    root =
      Path.join(System.tmp_dir!(), "lemon-changes-safety-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "status and diff run no clean filter, textconv or fsmonitor program", %{root: root} do
    repo = Path.join(root, "repo")
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    File.write!(Path.join(repo, "tracked.txt"), "one\n")
    File.write!(Path.join(repo, "stat-only.txt"), "same\n")
    git!(repo, ["add", "-A"])

    git!(repo, [
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

    marker = Path.join(root, "program-ran")
    git!(repo, ["config", "filter.evil.clean", program!(root, "clean", marker, "cat")])
    git!(repo, ["config", "diff.evil.textconv", program!(root, "textconv", marker, ~s(cat "$1"))])
    git!(repo, ["config", "core.fsmonitor", program!(root, "fsmonitor", marker, "exit 1")])
    File.write!(Path.join(repo, ".git/info/attributes"), "* filter=evil diff=evil\n")
    File.write!(Path.join(repo, "tracked.txt"), "two\n")
    File.touch!(Path.join(repo, "stat-only.txt"), {{2020, 1, 1}, {0, 0, 0}})

    assert {:ok, status} = call(%{"cwd" => repo})
    assert status["repository"] == true
    assert Enum.map(status["files"], & &1["path"]) == ["tracked.txt"]

    assert {:ok, %{"diff" => diff}} = call(%{"cwd" => repo, "path" => "tracked.txt"})
    assert diff["patch"] =~ "+two"
    refute File.exists?(marker), "sessions.changes ran a program named by repository config"
  end

  defp call(params),
    do: SessionsChanges.handle(Map.put_new(params, "sessionKey", @key), @operator_ctx)

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    out
  end

  defp program!(dir, name, marker, tail) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n: > '#{marker}'\n#{tail}\n")
    File.chmod!(path, 0o755)
    path
  end
end
