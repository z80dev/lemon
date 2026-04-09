defmodule CodingAgent.Tools.Task.WorkspaceTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task.Workspace

  test "uses scratch workspace for external text-only tasks" do
    cwd =
      Workspace.resolve_effective_cwd(
        %{
          engine: "codex",
          description: "Write a joke",
          prompt: "Write a short joke about compilers.",
          role_id: nil,
          cwd: nil
        },
        "/home/z80/dev/lemon",
        task_id: "task_text_only"
      )

    assert cwd == Path.join([System.tmp_dir!(), "lemon-task-scratch", "task_text_only"])
    assert File.dir?(cwd)
  end

  test "keeps inherited workspace for external coding tasks" do
    cwd =
      Workspace.resolve_effective_cwd(
        %{
          engine: "codex",
          description: "Fix failing test",
          prompt: "Debug the failing mix test and patch the module.",
          role_id: nil,
          cwd: nil
        },
        "/home/z80/dev/lemon"
      )

    assert cwd == "/home/z80/dev/lemon"
  end

  test "keeps explicit cwd even for text-only tasks" do
    cwd =
      Workspace.resolve_effective_cwd(
        %{
          engine: "claude",
          description: "Write a riddle",
          prompt: "Write a short riddle.",
          role_id: nil,
          cwd: "/tmp/explicit-task-cwd"
        },
        "/home/z80/dev/lemon"
      )

    assert cwd == "/tmp/explicit-task-cwd"
  end
end
