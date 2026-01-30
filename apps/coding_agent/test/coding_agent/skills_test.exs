defmodule CodingAgent.SkillsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Skills

  @moduletag :tmp_dir

  describe "list/1" do
    test "returns empty list when no skills exist", %{tmp_dir: tmp_dir} do
      assert Skills.list(tmp_dir) == []
    end

    test "loads skills from project directory", %{tmp_dir: tmp_dir} do
      # Create skill directory structure
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "test-skill"])
      File.mkdir_p!(skill_dir)

      skill_content = """
      ---
      name: test-skill
      description: A test skill for testing
      ---

      ## Usage

      This is the skill content.
      """

      File.write!(Path.join(skill_dir, "SKILL.md"), skill_content)

      skills = Skills.list(tmp_dir)
      assert length(skills) == 1

      skill = hd(skills)
      assert skill.name == "test-skill"
      assert skill.description == "A test skill for testing"
      assert String.contains?(skill.content, "This is the skill content")
    end

    test "handles skills without description", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "no-desc"])
      File.mkdir_p!(skill_dir)

      skill_content = """
      ---
      name: no-desc
      ---

      Content only.
      """

      File.write!(Path.join(skill_dir, "SKILL.md"), skill_content)

      skills = Skills.list(tmp_dir)
      assert length(skills) == 1
      assert hd(skills).description == ""
    end

    test "uses directory name when name not in frontmatter", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "dir-name-skill"])
      File.mkdir_p!(skill_dir)

      skill_content = """
      ---
      description: Has description but no name
      ---

      Content here.
      """

      File.write!(Path.join(skill_dir, "SKILL.md"), skill_content)

      skills = Skills.list(tmp_dir)
      assert length(skills) == 1
      assert hd(skills).name == "dir-name-skill"
    end

    test "ignores files without frontmatter", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "no-frontmatter"])
      File.mkdir_p!(skill_dir)

      File.write!(Path.join(skill_dir, "SKILL.md"), "Just content, no frontmatter")

      skills = Skills.list(tmp_dir)
      assert skills == []
    end

    test "loads multiple skills", %{tmp_dir: tmp_dir} do
      for name <- ["skill-a", "skill-b", "skill-c"] do
        skill_dir = Path.join([tmp_dir, ".lemon", "skill", name])
        File.mkdir_p!(skill_dir)

        content = """
        ---
        name: #{name}
        description: Description for #{name}
        ---

        Content for #{name}.
        """

        File.write!(Path.join(skill_dir, "SKILL.md"), content)
      end

      skills = Skills.list(tmp_dir)
      assert length(skills) == 3
      names = Enum.map(skills, & &1.name)
      assert "skill-a" in names
      assert "skill-b" in names
      assert "skill-c" in names
    end
  end

  describe "get/2" do
    test "returns skill by name", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "my-skill"])
      File.mkdir_p!(skill_dir)

      content = """
      ---
      name: my-skill
      description: My skill description
      ---

      My skill content.
      """

      File.write!(Path.join(skill_dir, "SKILL.md"), content)

      skill = Skills.get(tmp_dir, "my-skill")
      assert skill != nil
      assert skill.name == "my-skill"
    end

    test "returns nil for non-existent skill", %{tmp_dir: tmp_dir} do
      assert Skills.get(tmp_dir, "non-existent") == nil
    end
  end

  describe "find_relevant/3" do
    test "finds skills matching context", %{tmp_dir: tmp_dir} do
      # Create file-io skill
      file_skill_dir = Path.join([tmp_dir, ".lemon", "skill", "file-io"])
      File.mkdir_p!(file_skill_dir)

      file_content = """
      ---
      name: file-io
      description: Use for file operations, reading, writing files
      ---

      File I/O patterns here.
      """

      File.write!(Path.join(file_skill_dir, "SKILL.md"), file_content)

      # Create database skill
      db_skill_dir = Path.join([tmp_dir, ".lemon", "skill", "database"])
      File.mkdir_p!(db_skill_dir)

      db_content = """
      ---
      name: database
      description: Use for database queries and SQL operations
      ---

      Database patterns here.
      """

      File.write!(Path.join(db_skill_dir, "SKILL.md"), db_content)

      # Search for file-related
      skills = Skills.find_relevant(tmp_dir, "reading a file", 3)
      assert length(skills) >= 1
      assert hd(skills).name == "file-io"

      # Search for database-related
      skills = Skills.find_relevant(tmp_dir, "SQL query database", 3)
      assert length(skills) >= 1
      assert hd(skills).name == "database"
    end

    test "returns empty list when nothing matches", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "specific"])
      File.mkdir_p!(skill_dir)

      content = """
      ---
      name: specific
      description: Very specific functionality
      ---

      Specific content.
      """

      File.write!(Path.join(skill_dir, "SKILL.md"), content)

      skills = Skills.find_relevant(tmp_dir, "completely unrelated xyz", 3)
      assert skills == []
    end

    test "respects max_results limit", %{tmp_dir: tmp_dir} do
      for i <- 1..5 do
        skill_dir = Path.join([tmp_dir, ".lemon", "skill", "skill-#{i}"])
        File.mkdir_p!(skill_dir)

        content = """
        ---
        name: skill-#{i}
        description: Common keyword here
        ---

        Content with common keyword.
        """

        File.write!(Path.join(skill_dir, "SKILL.md"), content)
      end

      skills = Skills.find_relevant(tmp_dir, "common keyword", 2)
      assert length(skills) == 2
    end
  end

  describe "format_for_prompt/1" do
    test "returns empty string for empty list" do
      assert Skills.format_for_prompt([]) == ""
    end

    test "formats skills as XML tags" do
      skills = [
        %{name: "skill-a", description: "desc", content: "Content A", path: "/path"},
        %{name: "skill-b", description: "desc", content: "Content B", path: "/path"}
      ]

      result = Skills.format_for_prompt(skills)

      assert String.contains?(result, "<skill name=\"skill-a\">")
      assert String.contains?(result, "Content A")
      assert String.contains?(result, "</skill>")
      assert String.contains?(result, "<skill name=\"skill-b\">")
      assert String.contains?(result, "Content B")
    end
  end

  describe "format_for_description/1" do
    test "returns empty string when no skills", %{tmp_dir: tmp_dir} do
      assert Skills.format_for_description(tmp_dir) == ""
    end

    test "formats skills as list", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "listed"])
      File.mkdir_p!(skill_dir)

      content = """
      ---
      name: listed
      description: A listed skill
      ---

      Content.
      """

      File.write!(Path.join(skill_dir, "SKILL.md"), content)

      result = Skills.format_for_description(tmp_dir)
      assert result == "- listed: A listed skill"
    end
  end
end
