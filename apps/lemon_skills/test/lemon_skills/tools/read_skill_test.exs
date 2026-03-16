defmodule LemonSkills.Tools.ReadSkillTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias LemonSkills.Tools.ReadSkill

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("HOME")
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")

    home = Path.join(tmp_dir, "home")
    agent_dir = Path.join(tmp_dir, "agent")

    File.mkdir_p!(home)
    File.mkdir_p!(agent_dir)

    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", agent_dir)
    LemonSkills.refresh()

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("LEMON_AGENT_DIR", previous_agent_dir)
      LemonSkills.refresh()
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "execute/5 — backwards compatible (default full view)" do
    test "returns helpful suggestions when the skill is not found", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "available-skill",
        """
        ---
        name: Available Skill
        description: Helpful suggestion for missing skills
        ---

        body
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: %{error: "not_found", key: "missing-skill"}
             } =
               ReadSkill.execute("call-1", %{"key" => "missing-skill"}, nil, nil, tmp_dir)

      assert text =~ "Skill not found: missing-skill"
      assert text =~ "Available skills:"
      assert text =~ "- available-skill: Helpful suggestion for missing skills"
    end

    test "returns metadata and SKILL.md content for a found skill", %{tmp_dir: tmp_dir} do
      path =
        write_skill!(
          tmp_dir,
          "demo-skill",
          """
          ---
          name: Demo Skill
          description: Demonstrates read_skill output
          ---

          ## Usage

          Use demo skill instructions.
          """
        )

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{
               content: [%TextContent{text: text}],
               details: %{key: "demo-skill", name: "Demo Skill", path: ^path}
             } = ReadSkill.execute("call-2", %{"key" => "demo-skill"}, nil, nil, tmp_dir)

      assert text =~ "# Skill: Demo Skill"
      assert text =~ "**Key:** demo-skill"
      assert text =~ "**Description:** Demonstrates read_skill output"
      assert text =~ "**Source:** Project (.lemon/skill)"
      assert text =~ "**Path:** #{path}"
      assert text =~ "## Content"
      assert text =~ "name: Demo Skill"
      assert text =~ "Use demo skill instructions."
      refute text =~ "## Status"
    end

    test "includes a status section when include_status is true", %{tmp_dir: tmp_dir} do
      missing_config = "READ_SKILL_STATUS_#{System.unique_integer([:positive])}"
      previous = System.get_env(missing_config)

      on_exit(fn -> restore_env(missing_config, previous) end)
      System.delete_env(missing_config)

      write_skill!(
        tmp_dir,
        "status-skill",
        """
        ---
        name: Status Skill
        description: Includes status output
        requires:
          config:
            - #{missing_config}
        ---

        body
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-3",
                 %{"key" => "status-skill", "include_status" => true},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "## Status"
      assert text =~ "**Ready:** false"
      assert text =~ "**Missing config:** #{missing_config}"
    end
  end

  describe "execute/5 — view: summary" do
    test "returns metadata without body content", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "summary-skill",
        """
        ---
        name: Summary Skill
        description: Tests summary view
        ---

        This body should NOT appear in summary view.
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-s1",
                 %{"key" => "summary-skill", "view" => "summary"},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "# Skill: Summary Skill"
      assert text =~ "**Key:** summary-skill"
      assert text =~ "**Description:** Tests summary view"
      assert text =~ "**Activation:**"
      refute text =~ "## Content"
      refute text =~ "This body should NOT appear"
    end

    test "summary with include_status still shows status section", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "summary-status-skill",
        """
        ---
        name: Summary Status
        description: Status summary test
        ---

        body content
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-s2",
                 %{"key" => "summary-status-skill", "view" => "summary", "include_status" => true},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "## Status"
      assert text =~ "**Ready:** true"
      refute text =~ "body content"
    end
  end

  describe "execute/5 — view: section" do
    test "extracts a specific heading section", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "sectioned-skill",
        """
        ---
        name: Sectioned Skill
        description: Has multiple sections
        ---

        ## Overview

        This is the overview section.

        ## Usage

        This is the usage section with specific instructions.

        ## Examples

        Some examples here.
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-sec1",
                 %{"key" => "sectioned-skill", "view" => "section", "section" => "Usage"},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "## Section: Usage"
      assert text =~ "usage section with specific instructions"
      refute text =~ "overview section"
      refute text =~ "Some examples here"
    end

    test "returns not-found message for missing section", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "nosection-skill",
        """
        ---
        name: No Section Skill
        description: Section test
        ---

        ## Existing

        Content.
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-sec2",
                 %{"key" => "nosection-skill", "view" => "section", "section" => "Missing"},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "Section 'Missing' not found"
    end

    test "returns guidance when section param is omitted", %{tmp_dir: tmp_dir} do
      write_skill!(tmp_dir, "nosection-param", "---\nname: x\ndescription: y\n---\nbody")
      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-sec3",
                 %{"key" => "nosection-param", "view" => "section"},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "No section specified"
    end
  end

  describe "execute/5 — view: file" do
    test "loads a referenced file from the skill directory", %{tmp_dir: tmp_dir} do
      skill_dir =
        write_skill!(
          tmp_dir,
          "file-skill",
          """
          ---
          name: File Skill
          description: Has extra files
          ---

          See extra.md for details.
          """
        )

      File.write!(Path.join(skill_dir, "extra.md"), "# Extra\n\nExtra content here.")

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-f1",
                 %{"key" => "file-skill", "view" => "file", "path" => "extra.md"},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "## File: extra.md"
      assert text =~ "Extra content here."
    end

    test "returns error for missing file", %{tmp_dir: tmp_dir} do
      write_skill!(tmp_dir, "nofile-skill", "---\nname: x\ndescription: y\n---\nbody")
      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-f2",
                 %{"key" => "nofile-skill", "view" => "file", "path" => "nonexistent.md"},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "Could not read 'nonexistent.md'"
    end

    test "rejects path traversal attempts", %{tmp_dir: tmp_dir} do
      write_skill!(tmp_dir, "traversal-skill", "---\nname: x\ndescription: y\n---\nbody")
      File.write!(Path.join(tmp_dir, "secret.txt"), "TOP SECRET")
      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-f3",
                 %{"key" => "traversal-skill", "view" => "file", "path" => "../../secret.txt"},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "outside the skill directory"
      refute text =~ "TOP SECRET"
    end

    test "returns guidance when path param is omitted", %{tmp_dir: tmp_dir} do
      write_skill!(tmp_dir, "nopath-skill", "---\nname: x\ndescription: y\n---\nbody")
      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-f4",
                 %{"key" => "nopath-skill", "view" => "file"},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "No path specified"
    end
  end

  describe "execute/5 — include_manifest" do
    test "includes manifest fields when include_manifest is true", %{tmp_dir: tmp_dir} do
      write_skill!(
        tmp_dir,
        "manifest-skill",
        """
        ---
        name: Manifest Skill
        description: Has manifest data
        platforms:
          - linux
          - darwin
        requires:
          bins:
            - curl
        ---

        body
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-m1",
                 %{"key" => "manifest-skill", "view" => "summary", "include_manifest" => true},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "## Manifest"
      assert text =~ "platforms:"
      assert text =~ "linux"
      assert text =~ "required_bins:"
      assert text =~ "curl"
    end

    test "omits manifest section when include_manifest is false", %{tmp_dir: tmp_dir} do
      write_skill!(tmp_dir, "no-manifest-skill", "---\nname: x\ndescription: y\n---\nbody")
      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-m2",
                 %{"key" => "no-manifest-skill", "include_manifest" => false},
                 nil,
                 nil,
                 tmp_dir
               )

      refute text =~ "## Manifest"
    end
  end

  describe "execute/5 — max_chars truncation" do
    test "truncates full content at max_chars", %{tmp_dir: tmp_dir} do
      long_body = String.duplicate("A", 5000)

      write_skill!(
        tmp_dir,
        "long-skill",
        """
        ---
        name: Long Skill
        description: Has long content
        ---

        #{long_body}
        """
      )

      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-t1",
                 %{"key" => "long-skill", "max_chars" => 200},
                 nil,
                 nil,
                 tmp_dir
               )

      assert text =~ "truncated at 200 chars"
      # Body portion should not have the full 5000 As
      refute String.contains?(text, String.duplicate("A", 5000))
    end

    test "does not truncate when content is within max_chars", %{tmp_dir: tmp_dir} do
      write_skill!(tmp_dir, "short-skill", "---\nname: Short\ndescription: Short skill\n---\nHi.")
      LemonSkills.refresh(cwd: tmp_dir)

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               ReadSkill.execute(
                 "call-t2",
                 %{"key" => "short-skill", "max_chars" => 10_000},
                 nil,
                 nil,
                 tmp_dir
               )

      refute text =~ "truncated"
      assert text =~ "Hi."
    end
  end

  defp write_skill!(tmp_dir, key, skill_md) do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", key])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
    skill_dir
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
