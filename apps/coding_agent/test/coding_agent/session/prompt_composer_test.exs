defmodule CodingAgent.Session.PromptComposerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.PromptComposer

  @moduletag :tmp_dir

  test "compose_system_prompt/6 keeps turn-specific skill relevance out of the prompt", %{
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

    github_prompt =
      PromptComposer.compose_system_prompt(
        tmp_dir,
        nil,
        nil,
        workspace_dir,
        :main,
        "please open a GitHub pull request and monitor CI"
      )

    unrelated_prompt =
      PromptComposer.compose_system_prompt(
        tmp_dir,
        nil,
        nil,
        workspace_dir,
        :main,
        "explain an unrelated algorithm"
      )

    assert github_prompt == unrelated_prompt
    refute String.contains?(github_prompt, "<relevant-skills>")
    assert String.contains?(github_prompt, "<key>github-pr-workflow</key>")
    assert String.contains?(github_prompt, "Use `read_skill` with <key>")
    refute String.contains?(github_prompt, "Full body should stay behind read_skill.")
  end
end
