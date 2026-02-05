defmodule CodingAgent.SystemPromptTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SystemPrompt

  @tag :tmp_dir
  test "injects workspace files into prompt", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "AGENTS content here")
    File.write!(Path.join(workspace_dir, "SOUL.md"), "SOUL content here")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        bootstrap_max_chars: 10_000
      })

    assert String.contains?(prompt, "You are a personal assistant running inside Lemon.")
    assert String.contains?(prompt, "## Workspace Files (injected)")
    assert String.contains?(prompt, "AGENTS content here")
    assert String.contains?(prompt, "SOUL content here")
  end
end
