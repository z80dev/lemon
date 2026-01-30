defmodule CodingAgent.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias CodingAgent.PromptBuilder

  @moduletag :tmp_dir

  describe "build/2" do
    test "returns base prompt when no extras", %{tmp_dir: tmp_dir} do
      result =
        PromptBuilder.build(tmp_dir, %{
          base_prompt: "You are helpful.",
          include_skills: false,
          include_commands: false,
          include_mentions: false
        })

      assert result == "You are helpful."
    end

    test "includes skills section when enabled", %{tmp_dir: tmp_dir} do
      # Create a skill
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "test-skill"])
      File.mkdir_p!(skill_dir)

      content = """
      ---
      name: test-skill
      description: For testing purposes
      ---

      Test skill content.
      """

      File.write!(Path.join(skill_dir, "SKILL.md"), content)

      result =
        PromptBuilder.build(tmp_dir, %{
          base_prompt: "Base.",
          context: "testing",
          include_skills: true,
          include_commands: false,
          include_mentions: false
        })

      assert String.contains?(result, "Base.")
      assert String.contains?(result, "<relevant-skills>")
      assert String.contains?(result, "test-skill")
    end

    test "includes commands section when enabled", %{tmp_dir: tmp_dir} do
      # Create a command
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Test command
      ---

      Do something.
      """

      File.write!(Path.join(cmd_dir, "test.md"), content)

      result =
        PromptBuilder.build(tmp_dir, %{
          base_prompt: "Base.",
          include_skills: false,
          include_commands: true,
          include_mentions: false
        })

      assert String.contains?(result, "<available-commands>")
      assert String.contains?(result, "/test")
    end

    test "includes mentions section when enabled", %{tmp_dir: tmp_dir} do
      # Create a subagent
      lemon_dir = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(lemon_dir)

      content =
        Jason.encode!([
          %{"id" => "helper", "description" => "A helper agent", "prompt" => "..."}
        ])

      File.write!(Path.join(lemon_dir, "subagents.json"), content)

      result =
        PromptBuilder.build(tmp_dir, %{
          base_prompt: "Base.",
          include_skills: false,
          include_commands: false,
          include_mentions: true
        })

      assert String.contains?(result, "<available-agents>")
      assert String.contains?(result, "@")
    end

    test "includes custom sections", %{tmp_dir: tmp_dir} do
      result =
        PromptBuilder.build(tmp_dir, %{
          base_prompt: "Base.",
          include_skills: false,
          include_commands: false,
          include_mentions: false,
          custom_sections: [{"rules", "Follow these rules."}]
        })

      assert String.contains?(result, "<rules>")
      assert String.contains?(result, "Follow these rules.")
      assert String.contains?(result, "</rules>")
    end
  end

  describe "build_skills_section/3" do
    test "returns empty string when no skills match", %{tmp_dir: tmp_dir} do
      result = PromptBuilder.build_skills_section(tmp_dir, "unrelated context", 3)
      assert result == ""
    end

    test "returns empty string for empty context", %{tmp_dir: tmp_dir} do
      result = PromptBuilder.build_skills_section(tmp_dir, "", 3)
      assert result == ""
    end

    test "returns formatted skills when matches found", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "file-io"])
      File.mkdir_p!(skill_dir)

      content = """
      ---
      name: file-io
      description: File operations and reading
      ---

      Use proper file handling.
      """

      File.write!(Path.join(skill_dir, "SKILL.md"), content)

      result = PromptBuilder.build_skills_section(tmp_dir, "file reading", 3)

      assert String.contains?(result, "<relevant-skills>")
      assert String.contains?(result, "file-io")
    end
  end

  describe "build_commands_section/1" do
    test "returns empty string when no commands", %{tmp_dir: tmp_dir} do
      result = PromptBuilder.build_commands_section(tmp_dir)
      assert result == ""
    end

    test "returns formatted commands when present", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      File.write!(
        Path.join(cmd_dir, "commit.md"),
        "---\ndescription: Commit changes\n---\nCommit."
      )

      result = PromptBuilder.build_commands_section(tmp_dir)

      assert String.contains?(result, "<available-commands>")
      assert String.contains?(result, "/commit")
    end
  end

  describe "build_mentions_section/1" do
    test "returns formatted agents section", %{tmp_dir: tmp_dir} do
      # Default subagents should be present
      result = PromptBuilder.build_mentions_section(tmp_dir)

      assert String.contains?(result, "<available-agents>")
      assert String.contains?(result, "@")
    end
  end

  describe "load_project_instructions/1" do
    test "returns empty string when no instruction files", %{tmp_dir: tmp_dir} do
      result = PromptBuilder.load_project_instructions(tmp_dir)
      assert result == ""
    end

    test "loads CLAUDE.md when present", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "# Project Instructions\nDo this.")

      result = PromptBuilder.load_project_instructions(tmp_dir)

      assert String.contains?(result, "Project Instructions")
      assert String.contains?(result, "Do this")
    end

    test "loads AGENTS.md when present", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "# Agent Guidelines\nFollow these.")

      result = PromptBuilder.load_project_instructions(tmp_dir)

      assert String.contains?(result, "Agent Guidelines")
    end

    test "prefers CLAUDE.md over AGENTS.md", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "CLAUDE content")
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "AGENTS content")

      result = PromptBuilder.load_project_instructions(tmp_dir)

      assert result == "CLAUDE content"
    end
  end

  describe "build_project_instructions_section/1" do
    test "returns empty string when no instructions", %{tmp_dir: tmp_dir} do
      result = PromptBuilder.build_project_instructions_section(tmp_dir)
      assert result == ""
    end

    test "wraps instructions in XML tags", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "Do the thing.")

      result = PromptBuilder.build_project_instructions_section(tmp_dir)

      assert String.contains?(result, "<project-instructions>")
      assert String.contains?(result, "Do the thing.")
      assert String.contains?(result, "</project-instructions>")
    end
  end
end
