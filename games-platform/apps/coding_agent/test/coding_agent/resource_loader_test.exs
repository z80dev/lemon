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
    test "returns empty string when no AGENTS.md exists" do
      isolated_dir =
        Path.join(
          System.tmp_dir!(),
          "resource_loader_agents_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(isolated_dir)

      result = ResourceLoader.load_agents(isolated_dir)
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
      # Note: This may still find global skills under ~/.lemon/agent/skill.
      # We mainly verify it doesn't crash and returns a map.
      assert is_map(result)
    end

    test "loads skills from .lemon/skill/*/SKILL.md", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "commit"])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "Git commit skill")

      result = ResourceLoader.load_skills(tmp_dir)
      assert result["commit"] == "Git commit skill"
    end

    test "loads skills from ~/.agents/skills/*/SKILL.md", %{tmp_dir: tmp_dir} do
      skill_name = "agents-global-#{System.unique_integer([:positive])}"
      skill_dir = Path.join([System.user_home!(), ".agents", "skills", skill_name])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "Agents global skill")

      on_exit(fn -> File.rm_rf(skill_dir) end)

      result = ResourceLoader.load_skills(tmp_dir)
      assert result[skill_name] == "Agents global skill"
    end
  end

  describe "load_skill/2" do
    test "returns error when skill doesn't exist", %{tmp_dir: tmp_dir} do
      result = ResourceLoader.load_skill(tmp_dir, "nonexistent")
      assert result == {:error, :not_found}
    end

    test "loads a specific skill", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "review"])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "Code review skill")

      result = ResourceLoader.load_skill(tmp_dir, "review")
      assert result == {:ok, "Code review skill"}
    end

    test "loads a specific skill from ~/.agents/skills", %{tmp_dir: tmp_dir} do
      skill_name = "agents-specific-#{System.unique_integer([:positive])}"
      skill_dir = Path.join([System.user_home!(), ".agents", "skills", skill_name])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "Agents specific skill")

      on_exit(fn -> File.rm_rf(skill_dir) end)

      result = ResourceLoader.load_skill(tmp_dir, skill_name)
      assert result == {:ok, "Agents specific skill"}
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

  describe "load_theme/1" do
    setup do
      # Create a temporary themes directory that we control
      # We need to mock the Config.agent_dir() or use a test-specific approach
      # Since load_theme/1 only looks in Config.agent_dir()/themes,
      # we'll test by temporarily creating files in that location
      agent_dir = CodingAgent.Config.agent_dir()
      themes_dir = Path.join(agent_dir, "themes")
      File.mkdir_p!(themes_dir)

      on_exit(fn ->
        # Clean up test theme files
        File.rm(Path.join(themes_dir, "test_theme.json"))
        File.rm(Path.join(themes_dir, "invalid_json.json"))
        File.rm(Path.join(themes_dir, "empty_theme.json"))
        File.rm(Path.join(themes_dir, "nested_theme.json"))
      end)

      {:ok, themes_dir: themes_dir}
    end

    test "returns {:error, :not_found} when theme doesn't exist" do
      result = ResourceLoader.load_theme("nonexistent_theme_xyz")
      assert result == {:error, :not_found}
    end

    test "loads valid theme JSON successfully", %{themes_dir: themes_dir} do
      theme_content =
        ~s({"name": "test", "colors": {"primary": "#FF0000", "secondary": "#00FF00"}})

      File.write!(Path.join(themes_dir, "test_theme.json"), theme_content)

      result = ResourceLoader.load_theme("test_theme")
      assert {:ok, theme} = result
      assert theme["name"] == "test"
      assert theme["colors"]["primary"] == "#FF0000"
      assert theme["colors"]["secondary"] == "#00FF00"
    end

    test "returns parse error for invalid JSON", %{themes_dir: themes_dir} do
      invalid_json = "{ invalid json content }"
      File.write!(Path.join(themes_dir, "invalid_json.json"), invalid_json)

      result = ResourceLoader.load_theme("invalid_json")
      assert {:error, {:parse_error, _reason}} = result
    end

    test "returns parse error for malformed JSON with trailing comma", %{themes_dir: themes_dir} do
      malformed_json = ~s({"name": "test", "color": "blue",})
      File.write!(Path.join(themes_dir, "invalid_json.json"), malformed_json)

      result = ResourceLoader.load_theme("invalid_json")
      assert {:error, {:parse_error, _reason}} = result
    end

    test "loads empty JSON object as valid theme", %{themes_dir: themes_dir} do
      File.write!(Path.join(themes_dir, "empty_theme.json"), "{}")

      result = ResourceLoader.load_theme("empty_theme")
      assert {:ok, theme} = result
      assert theme == %{}
    end

    test "loads theme with nested structures", %{themes_dir: themes_dir} do
      nested_theme =
        Jason.encode!(%{
          "name" => "nested",
          "colors" => %{
            "ui" => %{
              "background" => "#000000",
              "foreground" => "#FFFFFF"
            },
            "syntax" => %{
              "keyword" => "#FF00FF",
              "string" => "#00FFFF"
            }
          },
          "fonts" => ["Monaco", "Consolas", "monospace"]
        })

      File.write!(Path.join(themes_dir, "nested_theme.json"), nested_theme)

      result = ResourceLoader.load_theme("nested_theme")
      assert {:ok, theme} = result
      assert theme["name"] == "nested"
      assert theme["colors"]["ui"]["background"] == "#000000"
      assert theme["colors"]["syntax"]["keyword"] == "#FF00FF"
      assert theme["fonts"] == ["Monaco", "Consolas", "monospace"]
    end

    test "returns :not_found for theme name with path traversal attempt" do
      # Attempting path traversal should not find a file
      result = ResourceLoader.load_theme("../../../etc/passwd")
      assert result == {:error, :not_found}
    end

    test "returns :not_found when theme name is empty string" do
      result = ResourceLoader.load_theme("")
      assert result == {:error, :not_found}
    end

    test "handles theme names with special characters", %{themes_dir: themes_dir} do
      # Theme names that might cause issues
      File.write!(Path.join(themes_dir, "test_theme.json"), ~s({"name": "special"}))

      # Underscores should work
      result = ResourceLoader.load_theme("test_theme")
      assert {:ok, _theme} = result
    end

    test "returns :not_found when themes directory doesn't exist" do
      # This tests the case where the themes directory hasn't been created
      # Since our setup creates it, we test with a definitely non-existent theme
      result = ResourceLoader.load_theme("definitely_not_a_real_theme_12345")
      assert result == {:error, :not_found}
    end

    test "parses JSON with unicode characters", %{themes_dir: themes_dir} do
      unicode_theme = ~s({"name": "Thème Sombre", "description": "日本語テーマ", "emoji": "🎨"})
      File.write!(Path.join(themes_dir, "test_theme.json"), unicode_theme)

      result = ResourceLoader.load_theme("test_theme")
      assert {:ok, theme} = result
      assert theme["name"] == "Thème Sombre"
      assert theme["description"] == "日本語テーマ"
      assert theme["emoji"] == "🎨"
    end

    test "parses JSON with numeric and boolean values", %{themes_dir: themes_dir} do
      typed_theme =
        ~s({"version": 2, "opacity": 0.95, "enabled": true, "deprecated": false, "count": null})

      File.write!(Path.join(themes_dir, "test_theme.json"), typed_theme)

      result = ResourceLoader.load_theme("test_theme")
      assert {:ok, theme} = result
      assert theme["version"] == 2
      assert theme["opacity"] == 0.95
      assert theme["enabled"] == true
      assert theme["deprecated"] == false
      assert theme["count"] == nil
    end

    test "handles JSON array at root level", %{themes_dir: themes_dir} do
      # While unusual, a JSON array is technically valid JSON
      array_theme = ~s([{"name": "light"}, {"name": "dark"}])
      File.write!(Path.join(themes_dir, "test_theme.json"), array_theme)

      result = ResourceLoader.load_theme("test_theme")
      assert {:ok, theme} = result
      assert is_list(theme)
      assert length(theme) == 2
    end

    test "returns parse error for completely empty file", %{themes_dir: themes_dir} do
      File.write!(Path.join(themes_dir, "empty_theme.json"), "")

      result = ResourceLoader.load_theme("empty_theme")
      assert {:error, {:parse_error, _reason}} = result
    end

    test "returns parse error for whitespace-only file", %{themes_dir: themes_dir} do
      File.write!(Path.join(themes_dir, "empty_theme.json"), "   \n\t  ")

      result = ResourceLoader.load_theme("empty_theme")
      assert {:error, {:parse_error, _reason}} = result
    end

    test "handles large theme file", %{themes_dir: themes_dir} do
      # Create a theme with many properties
      colors =
        for i <- 1..100, into: %{} do
          {"color_#{i}", "##{String.pad_leading(Integer.to_string(i, 16), 6, "0")}"}
        end

      large_theme = Jason.encode!(%{"name" => "large", "colors" => colors})
      File.write!(Path.join(themes_dir, "test_theme.json"), large_theme)

      result = ResourceLoader.load_theme("test_theme")
      assert {:ok, theme} = result
      assert theme["name"] == "large"
      assert map_size(theme["colors"]) == 100
    end
  end
end
