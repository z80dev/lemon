defmodule LemonSkills.Tools.SkillManageTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Tools.SkillManage

  @moduletag :tmp_dir

  defp execute(tmp_dir, params) do
    tool = SkillManage.tool(cwd: tmp_dir)
    tool.execute.("call-1", params, nil, nil)
  end

  defp valid_skill(name \\ "Learned Workflow") do
    """
    ---
    name: #{name}
    description: Captures a learned workflow
    ---

    ## Usage

    Follow the proven workflow.
    """
  end

  describe "create" do
    test "creates a project skill and refreshes the registry", %{tmp_dir: tmp_dir} do
      result =
        execute(tmp_dir, %{
          "action" => "create",
          "name" => "learned-workflow",
          "content" => valid_skill()
        })

      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "learned-workflow"])

      assert result.details.action == "create"
      assert result.details.audit.status == "pass"
      assert File.regular?(Path.join(skill_dir, "SKILL.md"))
      assert {:ok, entry} = LemonSkills.Registry.get("learned-workflow", cwd: tmp_dir)
      assert entry.name == "Learned Workflow"
    end

    test "rejects invalid frontmatter before writing", %{tmp_dir: tmp_dir} do
      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "create",
                 "name" => "bad-skill",
                 "content" => "# Missing frontmatter"
               })

      assert message =~ "frontmatter"
      refute File.exists?(Path.join([tmp_dir, ".lemon", "skill", "bad-skill"]))
    end
  end

  describe "patch" do
    test "patches SKILL.md and keeps manifest valid", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "patchable-skill",
        "content" => valid_skill("Patchable Skill")
      })

      result =
        execute(tmp_dir, %{
          "action" => "patch",
          "name" => "patchable-skill",
          "old_string" => "Follow the proven workflow.",
          "new_string" => "Follow the updated proven workflow."
        })

      skill_file = Path.join([tmp_dir, ".lemon", "skill", "patchable-skill", "SKILL.md"])

      assert result.details.action == "patch"
      assert File.read!(skill_file) =~ "updated proven workflow"
    end

    test "requires replace_all for repeated matches", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "repeat-skill",
        "content" => """
        ---
        name: Repeat Skill
        description: Has repeated content
        ---

        foo
        foo
        """
      })

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "patch",
                 "name" => "repeat-skill",
                 "old_string" => "foo",
                 "new_string" => "bar"
               })

      assert message =~ "replace_all=true"
    end

    test "enforces supporting file size limits when patching", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "large-patch-skill",
        "content" => valid_skill("Large Patch Skill")
      })

      execute(tmp_dir, %{
        "action" => "write_file",
        "name" => "large-patch-skill",
        "file_path" => "references/guide.md",
        "file_content" => "small"
      })

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "patch",
                 "name" => "large-patch-skill",
                 "file_path" => "references/guide.md",
                 "old_string" => "small",
                 "new_string" => String.duplicate("x", 100_001)
               })

      assert message =~ "supporting file exceeds"
    end
  end

  describe "supporting files" do
    test "writes and removes a supporting file under an allowed directory", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "support-skill",
        "content" => valid_skill("Support Skill")
      })

      write_result =
        execute(tmp_dir, %{
          "action" => "write_file",
          "name" => "support-skill",
          "file_path" => "references/guide.md",
          "file_content" => "# Guide\n"
        })

      target = Path.join([tmp_dir, ".lemon", "skill", "support-skill", "references", "guide.md"])

      assert write_result.details.action == "write_file"
      assert File.read!(target) == "# Guide\n"

      remove_result =
        execute(tmp_dir, %{
          "action" => "remove_file",
          "name" => "support-skill",
          "file_path" => "references/guide.md"
        })

      assert remove_result.details.action == "remove_file"
      refute File.exists?(target)
    end

    test "rejects path traversal for supporting files", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "traversal-skill",
        "content" => valid_skill("Traversal Skill")
      })

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "write_file",
                 "name" => "traversal-skill",
                 "file_path" => "references/../../escape.md",
                 "file_content" => "bad"
               })

      assert message =~ "may not contain '..'"
    end

    test "rejects writes through symlinked support directories", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "symlink-skill",
        "content" => valid_skill("Symlink Skill")
      })

      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "symlink-skill"])
      outside_dir = Path.join(tmp_dir, "outside")
      File.mkdir_p!(outside_dir)
      File.rm_rf!(Path.join(skill_dir, "references"))
      :ok = File.ln_s(outside_dir, Path.join(skill_dir, "references"))

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "write_file",
                 "name" => "symlink-skill",
                 "file_path" => "references/guide.md",
                 "file_content" => "bad"
               })

      assert message =~ "refusing to write through symlink"
      refute File.exists?(Path.join(outside_dir, "guide.md"))
    end

    test "rejects patches through symlinked support directories", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "symlink-patch-skill",
        "content" => valid_skill("Symlink Patch Skill")
      })

      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "symlink-patch-skill"])
      outside_dir = Path.join(tmp_dir, "outside-patch")
      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "guide.md"), "outside")
      File.rm_rf!(Path.join(skill_dir, "references"))
      :ok = File.ln_s(outside_dir, Path.join(skill_dir, "references"))

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "patch",
                 "name" => "symlink-patch-skill",
                 "file_path" => "references/guide.md",
                 "old_string" => "outside",
                 "new_string" => "changed"
               })

      assert message =~ "refusing to write through symlink"
      assert File.read!(Path.join(outside_dir, "guide.md")) == "outside"
    end

    test "rejects removals through symlinked support directories", %{tmp_dir: tmp_dir} do
      execute(tmp_dir, %{
        "action" => "create",
        "name" => "symlink-remove-skill",
        "content" => valid_skill("Symlink Remove Skill")
      })

      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "symlink-remove-skill"])
      outside_dir = Path.join(tmp_dir, "outside-remove")
      outside_file = Path.join(outside_dir, "guide.md")
      File.mkdir_p!(outside_dir)
      File.write!(outside_file, "outside")
      File.rm_rf!(Path.join(skill_dir, "references"))
      :ok = File.ln_s(outside_dir, Path.join(skill_dir, "references"))

      assert {:error, message} =
               execute(tmp_dir, %{
                 "action" => "remove_file",
                 "name" => "symlink-remove-skill",
                 "file_path" => "references/guide.md"
               })

      assert message =~ "refusing to write through symlink"
      assert File.exists?(outside_file)
    end
  end
end
