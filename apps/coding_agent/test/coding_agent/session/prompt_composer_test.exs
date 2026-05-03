defmodule CodingAgent.Session.PromptComposerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.PromptComposer

  @moduletag :tmp_dir

  test "compose_system_prompt/6 injects relevant skills for current prompt context", %{
    tmp_dir: tmp_dir
  } do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "workspace agents")

    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "github-pr-workflow"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: github-pr-workflow
      description: GitHub pull request lifecycle, CI checks, branches, commits, PR creation
      keywords:
        - github
        - pull request
        - ci
      ---

      Full body should stay behind read_skill.
      """
    )

    prompt =
      PromptComposer.compose_system_prompt(
        tmp_dir,
        nil,
        nil,
        workspace_dir,
        :main,
        "please open a GitHub pull request and monitor CI"
      )

    assert String.contains?(prompt, "<relevant-skills>")
    assert String.contains?(prompt, "github-pr-workflow")
    assert String.contains?(prompt, "Use `read_skill` with <key>")
    refute String.contains?(prompt, "Full body should stay behind read_skill.")
  end
end
