defmodule CodingAgent.ResourceLoaderTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ResourceLoader

  @moduletag :tmp_dir

  describe "load_instructions/1" do
    test "loads from tmp_dir even when no local files exist", %{tmp_dir: tmp_dir} do
      # Note: This may still find global files in ~/.claude/ etc.
      # We just verify it doesn't crash and returns a string
      result = ResourceLoader.load_instructions(tmp_dir)
      assert is_binary(result)
    end

    test "loads CLAUDE.md from cwd", %{tmp_dir: tmp_dir} do
      claude_path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(claude_path, "# Project Instructions\nDo good things.")

      result = ResourceLoader.load_instructions(tmp_dir)
      assert result =~ "# Project Instructions"
      assert result =~ "Do good things."
      assert result =~ "<!-- From: #{claude_path} -->"
    end

    test "loads from .claude subdirectory", %{tmp_dir: tmp_dir} do
      claude_dir = Path.join(tmp_dir, ".claude")
      File.mkdir_p!(claude_dir)
      File.write!(Path.join(claude_dir, "CLAUDE.md"), "Hidden claude config")

      result = ResourceLoader.load_instructions(tmp_dir)
      assert result =~ "Hidden claude config"
    end

    test "loads from .lemon subdirectory", %{tmp_dir: tmp_dir} do
      lemon_dir = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(lemon_dir)
      File.write!(Path.join(lemon_dir, "CLAUDE.md"), "Lemon config")

      result = ResourceLoader.load_instructions(tmp_dir)
      assert result =~ "Lemon config"
    end

    test "combines multiple instruction files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "Root config")
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "Agent config")

      result = ResourceLoader.load_instructions(tmp_dir)
      assert result =~ "Root config"
      assert result =~ "Agent config"
    end

    test "loads from parent directories", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "sub/project")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "Parent config")
      File.write!(Path.join(subdir, "CLAUDE.md"), "Child config")

      result = ResourceLoader.load_instructions(subdir)
      # Both should be included
      assert result =~ "Child config"
      assert result =~ "Parent config"
    end
  end

  describe "load_instructions_list/1" do
    test "returns list of files with metadata", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "Test content")

      result = ResourceLoader.load_instructions_list(tmp_dir)
      assert is_list(result)
      assert length(result) >= 1

      file = Enum.find(result, &(&1.path =~ "CLAUDE.md"))
      assert file != nil
      assert file.content == "Test content"
    end
  end

  describe "load_agents/1" do
    test "returns empty string when no AGENTS.md exists", %{tmp_dir: tmp_dir} do
      result = ResourceLoader.load_agents(tmp_dir)
      assert result == ""
    end

    test "loads AGENTS.md from cwd", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "# Agent Definitions")

      result = ResourceLoader.load_agents(tmp_dir)
      assert result =~ "# Agent Definitions"
    end
  end

  describe "load_prompts/1" do
    test "returns empty map when no prompts exist", %{tmp_dir: tmp_dir} do
      result = ResourceLoader.load_prompts(tmp_dir)
      assert result == %{}
    end

    test "loads prompts from .lemon/prompts", %{tmp_dir: tmp_dir} do
      prompts_dir = Path.join(tmp_dir, ".lemon/prompts")
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "review.md"), "Review this code")
      File.write!(Path.join(prompts_dir, "refactor.txt"), "Refactor this")

      result = ResourceLoader.load_prompts(tmp_dir)
      assert result["review"] == "Review this code"
      assert result["refactor"] == "Refactor this"
    end
  end

  describe "load_prompt/2" do
    test "returns error when prompt doesn't exist", %{tmp_dir: tmp_dir} do
      result = ResourceLoader.load_prompt(tmp_dir, "nonexistent")
      assert result == {:error, :not_found}
    end

    test "loads a specific prompt", %{tmp_dir: tmp_dir} do
      prompts_dir = Path.join(tmp_dir, ".lemon/prompts")
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "test.md"), "Test prompt content")

      result = ResourceLoader.load_prompt(tmp_dir, "test")
      assert result == {:ok, "Test prompt content"}
    end
  end

  describe "load_skills/1" do
    test "returns empty map when no skills exist", %{tmp_dir: tmp_dir} do
      result = ResourceLoader.load_skills(tmp_dir)
      assert result == %{}
    end

    test "loads skills from .lemon/skills", %{tmp_dir: tmp_dir} do
      skills_dir = Path.join(tmp_dir, ".lemon/skills")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "commit.md"), "Git commit skill")

      result = ResourceLoader.load_skills(tmp_dir)
      assert result["commit"] == "Git commit skill"
    end
  end

  describe "load_skill/2" do
    test "returns error when skill doesn't exist", %{tmp_dir: tmp_dir} do
      result = ResourceLoader.load_skill(tmp_dir, "nonexistent")
      assert result == {:error, :not_found}
    end

    test "loads a specific skill", %{tmp_dir: tmp_dir} do
      skills_dir = Path.join(tmp_dir, ".lemon/skills")
      File.mkdir_p!(skills_dir)
      File.write!(Path.join(skills_dir, "review.md"), "Code review skill")

      result = ResourceLoader.load_skill(tmp_dir, "review")
      assert result == {:ok, "Code review skill"}
    end
  end

  describe "resource_exists?/2" do
    test "returns false when file doesn't exist", %{tmp_dir: tmp_dir} do
      refute ResourceLoader.resource_exists?(tmp_dir, "NONEXISTENT.md")
    end

    test "returns true when file exists", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "test")
      assert ResourceLoader.resource_exists?(tmp_dir, "CLAUDE.md")
    end
  end
end
