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

  describe "execute/5" do
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

  defp write_skill!(tmp_dir, key, skill_md) do
    skill_dir = Path.join([tmp_dir, ".lemon", "skill", key])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), skill_md)
    skill_dir
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
