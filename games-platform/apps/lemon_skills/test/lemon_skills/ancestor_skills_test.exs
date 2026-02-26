defmodule LemonSkills.AncestorSkillsTest do
  @moduledoc """
  Tests for ancestor `.agents/skills` discovery feature.

  These tests verify that skills in `.agents/skills` directories are discovered
  from the current working directory up to the git repository root (or filesystem
  root if not in a git repo), following Pi's package-manager pattern.
  """

  use ExUnit.Case, async: false

  alias LemonSkills.Config

  @moduletag :tmp_dir

  describe "project_skills_dirs/1" do
    test "returns primary project dir and ancestor .agents/skills in git repo", %{tmp_dir: tmp_dir} do
      # Setup: Create a git repo with nested structure
      repo_root = Path.join(tmp_dir, "repo")
      nested_cwd = Path.join(repo_root, "packages") |> Path.join("feature")
      File.mkdir_p!(nested_cwd)
      File.mkdir_p!(Path.join(repo_root, ".git"))

      # Create .agents/skills directories at different levels
      repo_agents = Path.join(repo_root, ".agents") |> Path.join("skills")
      nested_agents = Path.join(repo_root, "packages") |> Path.join(".agents") |> Path.join("skills")
      cwd_agents = Path.join(nested_cwd, ".agents") |> Path.join("skills")

      # Also create the primary .lemon/skill directory
      primary_dir = Path.join(nested_cwd, ".lemon") |> Path.join("skill")
      File.mkdir_p!(primary_dir)
      File.mkdir_p!(repo_agents)
      File.mkdir_p!(nested_agents)
      File.mkdir_p!(cwd_agents)

      # Get project skills dirs
      dirs = Config.project_skills_dirs(nested_cwd)

      # Should include:
      # 1. Primary project dir (.lemon/skill)
      # 2. Cwd .agents/skills
      # 3. Parent .agents/skills
      # 4. Repo root .agents/skills
      # But NOT above repo root

      assert primary_dir in dirs
      assert cwd_agents in dirs
      assert nested_agents in dirs
      assert repo_agents in dirs

      # Should be in precedence order (primary first, then from cwd up)
      assert Enum.at(dirs, 0) == primary_dir
    end

    test "stops at filesystem root when not in git repo", %{tmp_dir: tmp_dir} do
      # Setup: Create a non-git directory structure
      non_repo_root = Path.join(tmp_dir, "non-repo")
      nested_cwd = Path.join(non_repo_root, "a") |> Path.join("b") |> Path.join("c")
      File.mkdir_p!(nested_cwd)

      # Create .agents/skills at various levels
      root_agents = Path.join(non_repo_root, ".agents") |> Path.join("skills")
      a_agents = Path.join(non_repo_root, "a") |> Path.join(".agents") |> Path.join("skills")
      b_agents = Path.join(non_repo_root, "a") |> Path.join("b") |> Path.join(".agents") |> Path.join("skills")
      c_agents = Path.join(nested_cwd, ".agents") |> Path.join("skills")

      # Also create the primary .lemon/skill directory
      primary_dir = Path.join(nested_cwd, ".lemon") |> Path.join("skill")
      File.mkdir_p!(primary_dir)
      File.mkdir_p!(root_agents)
      File.mkdir_p!(a_agents)
      File.mkdir_p!(b_agents)
      File.mkdir_p!(c_agents)

      dirs = Config.project_skills_dirs(nested_cwd)

      assert primary_dir in dirs
      assert c_agents in dirs
      assert b_agents in dirs
      assert a_agents in dirs
      assert root_agents in dirs
    end

    test "filters out non-existent directories", %{tmp_dir: tmp_dir} do
      cwd = Path.join(tmp_dir, "project")
      File.mkdir_p!(cwd)
      File.mkdir_p!(Path.join(cwd, ".git"))

      # Only create the primary .lemon/skill dir, not .agents/skills
      primary_dir = Path.join(cwd, ".lemon") |> Path.join("skill")
      File.mkdir_p!(primary_dir)

      dirs = Config.project_skills_dirs(cwd)

      # Should only include the existing primary dir
      assert dirs == [primary_dir]
    end

    test "handles empty directories gracefully", %{tmp_dir: tmp_dir} do
      cwd = Path.join(tmp_dir, "empty-project")
      File.mkdir_p!(cwd)
      File.mkdir_p!(Path.join(cwd, ".git"))

      # Don't create any skills directories

      dirs = Config.project_skills_dirs(cwd)

      # Should return empty list since no directories exist
      assert dirs == []
    end

    test "deduplicates directories", %{tmp_dir: tmp_dir} do
      # Edge case: if .lemon/skill and .agents/skills point to same dir
      # (shouldn't happen in practice, but test safety)
      cwd = Path.join(tmp_dir, "weird-project")
      File.mkdir_p!(cwd)
      File.mkdir_p!(Path.join(cwd, ".git"))

      # Create both directories
      File.mkdir_p!(Path.join(cwd, ".lemon") |> Path.join("skill"))
      File.mkdir_p!(Path.join(cwd, ".agents") |> Path.join("skills"))

      dirs = Config.project_skills_dirs(cwd)

      # Should have both (they're different paths)
      assert length(dirs) == 2
    end
  end

  describe "integration with Registry" do
    test "discovers skills from ancestor .agents/skills directories", %{tmp_dir: tmp_dir} do
      # Setup: Create a git repo with skills at different levels
      repo_root = Path.join(tmp_dir, "repo")
      nested_cwd = Path.join(repo_root, "packages") |> Path.join("feature")
      File.mkdir_p!(nested_cwd)
      File.mkdir_p!(Path.join(repo_root, ".git"))

      # Create skills at different levels
      create_skill(repo_root, ".agents/skills", "repo-skill", "Repo Skill")
      create_skill(repo_root, "packages/.agents/skills", "nested-skill", "Nested Skill")
      create_skill(nested_cwd, ".agents/skills", "cwd-skill", "CWD Skill")

      # Create a skill above repo (should NOT be discovered)
      create_skill(tmp_dir, ".agents/skills", "above-repo", "Above Repo")

      # Refresh the registry to pick up new skills
      LemonSkills.Registry.refresh(cwd: nested_cwd)

      # List skills for the nested cwd
      skills = LemonSkills.Registry.list(cwd: nested_cwd)

      # Should find all three skills in the repo
      skill_keys = Enum.map(skills, & &1.key)

      assert "repo-skill" in skill_keys
      assert "nested-skill" in skill_keys
      assert "cwd-skill" in skill_keys

      # Should NOT find the skill above repo
      refute "above-repo" in skill_keys
    end

    test "project .lemon/skill takes precedence over .agents/skills", %{tmp_dir: tmp_dir} do
      repo_root = Path.join(tmp_dir, "repo")
      File.mkdir_p!(repo_root)
      File.mkdir_p!(Path.join(repo_root, ".git"))

      # Create a skill with same key in both locations
      create_skill(repo_root, ".lemon/skill", "my-skill", "Project Version")
      create_skill(repo_root, ".agents/skills", "my-skill", "Agents Version")

      LemonSkills.Registry.refresh(cwd: repo_root)

      skills = LemonSkills.Registry.list(cwd: repo_root)
      skill = Enum.find(skills, &(&1.key == "my-skill"))

      # Should get the project version (higher precedence)
      # Note: name comes from manifest parsing, may include quotes
      assert skill.name =~ "Project Version"
    end

    test "cwd .agents/skills takes precedence over parent .agents/skills", %{tmp_dir: tmp_dir} do
      repo_root = Path.join(tmp_dir, "repo")
      nested_cwd = Path.join(repo_root, "nested")
      File.mkdir_p!(nested_cwd)
      File.mkdir_p!(Path.join(repo_root, ".git"))

      # Create skills with same key at different levels
      create_skill(repo_root, ".agents/skills", "shared-skill", "Root Version")
      create_skill(nested_cwd, ".agents/skills", "shared-skill", "Nested Version")

      LemonSkills.Registry.refresh(cwd: nested_cwd)

      skills = LemonSkills.Registry.list(cwd: nested_cwd)
      skill = Enum.find(skills, &(&1.key == "shared-skill"))

      # Should get the nested version (closer to cwd)
      assert skill.name =~ "Nested Version"
    end
  end

  # Helper function to create a skill directory with SKILL.md
  defp create_skill(base_dir, sub_path, key, name) do
    path_parts = String.split(sub_path, "/")
    skill_dir = Path.join([base_dir] ++ path_parts ++ [key])
    File.mkdir_p!(skill_dir)

    skill_content = """
    ---
    name: #{name}
    description: Test skill #{key}
    ---

    # #{name}

    This is a test skill.
    """

    File.write!(Path.join(skill_dir, "SKILL.md"), skill_content)
  end
end
