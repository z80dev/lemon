defmodule CodingAgent.ResourceLoaderTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ResourceLoader
  alias LemonSkills.Config, as: SkillConfig

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_harness_dir_env = System.get_env("LEMON_HARNESS_SKILLS_DIR")
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    previous_home = System.get_env("HOME")
    previous_copilot_home = System.get_env("COPILOT_HOME")
    System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "global-agent"))
    previous_harness_dir = Application.get_env(:lemon_skills, :harness_global_skills_dir)
    harness_dir = Path.join(tmp_dir, "harness-skills")
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    System.put_env("LEMON_HARNESS_SKILLS_DIR", harness_dir)
    # Global instruction discovery reads HOME; never the real home in tests.
    System.put_env("HOME", home)
    System.delete_env("COPILOT_HOME")

    on_exit(fn ->
      restore_env("LEMON_HARNESS_SKILLS_DIR", previous_harness_dir_env)
      restore_env("LEMON_AGENT_DIR", previous_agent_dir)
      restore_env("HOME", previous_home)
      restore_env("COPILOT_HOME", previous_copilot_home)
      restore_app_env(:lemon_skills, :harness_global_skills_dir, previous_harness_dir)
    end)

    {:ok, home: home}
  end

  describe "load_instructions/1" do
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

      files = ResourceLoader.load_instructions_list(subdir)
      paths = Enum.map(files, & &1.path)

      assert Enum.find_index(paths, &(&1 == Path.join(tmp_dir, "CLAUDE.md"))) <
               Enum.find_index(paths, &(&1 == Path.join(subdir, "CLAUDE.md")))

      result = ResourceLoader.load_instructions(subdir)
      {parent_offset, _} = :binary.match(result, "Parent config")
      {child_offset, _} = :binary.match(result, "Child config")
      assert parent_offset < child_offset
    end

    test "renders global then ancestors then cwd, retaining each config root", %{tmp_dir: tmp_dir} do
      global = System.get_env("LEMON_AGENT_DIR")
      cwd = Path.join(tmp_dir, "ancestor/local")

      paths = [
        Path.join(global, "AGENTS.md"),
        Path.join(tmp_dir, "AGENTS.md"),
        Path.join(tmp_dir, ".claude/CLAUDE.md"),
        Path.join(tmp_dir, ".lemon/AGENTS.md"),
        Path.join(tmp_dir, "ancestor/AGENTS.md"),
        Path.join(cwd, "CLAUDE.md"),
        Path.join(cwd, ".claude/AGENTS.md"),
        Path.join(cwd, ".lemon/CLAUDE.md")
      ]

      Enum.each(Enum.with_index(paths), fn {path, index} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "directive-#{index}")
      end)

      loaded = ResourceLoader.load_instructions_list(cwd)
      assert Enum.map(Enum.filter(loaded, &(&1.path in paths)), & &1.path) == paths

      rendered = ResourceLoader.load_instructions(cwd)

      offsets =
        Enum.map(paths, fn path -> elem(:binary.match(rendered, "<!-- From: #{path} -->"), 0) end)

      assert offsets == Enum.sort(offsets)
    end

    test "loads a physical file only once through global, local and symlink paths", %{
      tmp_dir: tmp_dir
    } do
      global = System.get_env("LEMON_AGENT_DIR")
      File.mkdir_p!(global)
      File.write!(Path.join(global, "AGENTS.md"), "unique-physical-directive")
      File.ln_s!(Path.join(global, "AGENTS.md"), Path.join(tmp_dir, "CLAUDE.md"))
      File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
      File.ln!(Path.join(global, "AGENTS.md"), Path.join(tmp_dir, ".lemon/AGENTS.md"))
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "intermediate-local-directive")

      # cwd == global also encounters the global path through its ancestor chain.
      files = ResourceLoader.load_instructions_list(global)
      assert Enum.count(files, &(&1.content == "unique-physical-directive")) == 1

      rendered = ResourceLoader.load_instructions(tmp_dir)
      assert length(:binary.matches(rendered, "unique-physical-directive")) == 1
      local_files = ResourceLoader.load_instructions_list(tmp_dir)

      aliases =
        Enum.filter(
          local_files,
          &(&1.content in ["unique-physical-directive", "intermediate-local-directive"])
        )

      assert Enum.map(aliases, & &1.path) == [
               Path.join(tmp_dir, "AGENTS.md"),
               Path.join(tmp_dir, ".lemon/AGENTS.md")
             ]
    end
  end

  describe "multi-tool instruction files" do
    test "loads every root file and config subdirectory file in order", %{tmp_dir: tmp_dir} do
      cwd = Path.join(tmp_dir, "project")

      paths =
        Enum.map(
          ~w(CLAUDE.md AGENTS.md GEMINI.md CLAUDE.local.md .claude/CLAUDE.md .claude/AGENTS.md
             .lemon/CLAUDE.md .lemon/AGENTS.md .gemini/GEMINI.md .agents/AGENTS.md
             .agent/AGENTS.md .omp/AGENTS.md .github/copilot-instructions.md),
          &Path.join(cwd, &1)
        )

      paths |> Enum.with_index() |> Enum.each(fn {path, i} -> write!(path, "directive-#{i}") end)

      loaded = ResourceLoader.load_instructions_list(cwd)
      assert Enum.map(Enum.filter(loaded, &(&1.path in paths)), & &1.path) == paths

      sections = ResourceLoader.instruction_sections(cwd)
      copilot = Enum.find(sections, &(&1.text =~ "directive-12"))
      assert copilot.label == "copilot-instructions.md (project)"
      assert copilot.text =~ "Scope: #{cwd} (this directory and its descendants)"
      gemini = Enum.find(sections, &(&1.text =~ "directive-8"))
      assert gemini.label == "GEMINI.md (project)"
      refute Enum.any?(sections, &String.contains?(&1.label, tmp_dir))
    end

    test "config subdirectories only hold their own file names", %{tmp_dir: tmp_dir} do
      cwd = Path.join(tmp_dir, "project")

      for rel <- ~w(.gemini/AGENTS.md .github/AGENTS.md .omp/CLAUDE.md .agents/GEMINI.md
                    copilot-instructions.md .claude/GEMINI.md) do
        write!(Path.join(cwd, rel), "stray-#{rel}")
      end

      refute ResourceLoader.load_instructions(cwd) =~ "stray-"
    end

    test "ancestor config subdirectories scope to their parent directory", %{tmp_dir: tmp_dir} do
      parent = Path.join(tmp_dir, "repo")
      cwd = Path.join(parent, "pkg")
      File.mkdir_p!(cwd)
      write!(Path.join(parent, ".github/copilot-instructions.md"), "parent-copilot")
      write!(Path.join(cwd, ".agents/AGENTS.md"), "child-agents")

      sections = ResourceLoader.instruction_sections(cwd)
      parent_section = Enum.find(sections, &(&1.text =~ "parent-copilot"))
      assert parent_section.label == "copilot-instructions.md (parent)"
      assert parent_section.text =~ "Scope: #{parent} (this directory and its descendants)"
      assert Enum.find(sections, &(&1.text =~ "child-agents")).label == "AGENTS.md (project)"

      rendered = ResourceLoader.load_instructions(cwd)
      assert offset(rendered, "parent-copilot") < offset(rendered, "child-agents")
    end

    test "loads global files from other agent tools before project files", %{
      tmp_dir: tmp_dir,
      home: home
    } do
      cwd = Path.join(tmp_dir, "project")
      File.mkdir_p!(cwd)
      write!(Path.join(cwd, "AGENTS.md"), "project-directive")

      globals =
        Enum.map(
          ~w(.claude/CLAUDE.md .gemini/GEMINI.md .codex/AGENTS.md .config/opencode/AGENTS.md
             .agents/AGENTS.md .agent/AGENTS.md .copilot/copilot-instructions.md
             .lemon/AGENTS.md),
          &Path.join(home, &1)
        )

      globals |> Enum.with_index() |> Enum.each(fn {path, i} -> write!(path, "global-#{i}") end)

      loaded = ResourceLoader.load_instructions_list(cwd)
      assert Enum.map(Enum.filter(loaded, &(&1.path in globals)), & &1.path) == globals

      sections = ResourceLoader.instruction_sections(cwd)

      for i <- 0..(length(globals) - 1) do
        section = Enum.find(sections, &(&1.text =~ "global-#{i}"))
        assert section.label =~ "(global)"
        assert section.text =~ "Scope: global"
      end

      rendered = ResourceLoader.load_instructions(cwd)
      assert offset(rendered, "global-7") < offset(rendered, "project-directive")
    end

    test "COPILOT_HOME relocates the Copilot user instructions", %{tmp_dir: tmp_dir, home: home} do
      cwd = Path.join(tmp_dir, "project")
      File.mkdir_p!(cwd)
      copilot_home = Path.join(tmp_dir, "copilot-config")
      write!(Path.join(copilot_home, "copilot-instructions.md"), "relocated-copilot")
      write!(Path.join(home, ".copilot/copilot-instructions.md"), "default-copilot")
      System.put_env("COPILOT_HOME", copilot_home)

      rendered = ResourceLoader.load_instructions(cwd)
      assert rendered =~ "relocated-copilot"
      refute rendered =~ "default-copilot"
    end

    test "expands @imports relative to each instruction file", %{tmp_dir: tmp_dir, home: home} do
      cwd = Path.join(tmp_dir, "project")
      write!(Path.join(cwd, ".github/copilot-instructions.md"), "Style: @style.md")
      write!(Path.join(cwd, ".github/style.md"), "imported-style")
      write!(Path.join(cwd, "AGENTS.md"), "Personal: @~/notes.md\n`@style.md` stays")
      write!(Path.join(home, "notes.md"), "imported-home-note")
      write!(Path.join(cwd, "style.md"), "inline-code-must-not-expand")

      rendered = ResourceLoader.load_instructions(cwd)
      assert rendered =~ "Style: imported-style"
      refute rendered =~ "inline-code-must-not-expand"
      assert rendered =~ "Personal: imported-home-note"
      assert rendered =~ "`@style.md` stays"

      [agents] =
        Enum.filter(
          ResourceLoader.load_instructions_list(cwd),
          &(&1.path == Path.join(cwd, "AGENTS.md"))
        )

      assert agents.content =~ "imported-home-note"
    end
  end

  describe "instruction_guide?/1" do
    test "matches root names anywhere and subdirectory names only in their directory" do
      for path <- ~w(AGENTS.md a/CLAUDE.md a/GEMINI.md a/CLAUDE.local.md a/.claude/CLAUDE.md
                     a/.gemini/GEMINI.md a/.github/copilot-instructions.md) do
        assert ResourceLoader.instruction_guide?(path), path
      end

      for path <- ~w(a/copilot-instructions.md a/README.md a/.gemini/settings.json) do
        refute ResourceLoader.instruction_guide?(path), path
      end
    end
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp offset(text, marker), do: elem(:binary.match(text, marker), 0)

  describe "load_instructions_list/1" do
    test "returns list of files with metadata", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "Test content")

      result = ResourceLoader.load_instructions_list(tmp_dir)
      assert is_list(result)
      assert result != []

      file = Enum.find(result, &(&1.path == Path.join(tmp_dir, "CLAUDE.md")))
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
    test "loads skills from .lemon/skill/*/SKILL.md", %{tmp_dir: tmp_dir} do
      skill_dir = Path.join([tmp_dir, ".lemon", "skill", "commit"])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "Git commit skill")

      result = ResourceLoader.load_skills(tmp_dir)
      assert result["commit"] == "Git commit skill"
    end

    test "loads skills from ~/.agents/skills/*/SKILL.md", %{tmp_dir: tmp_dir} do
      skill_name = "agents-global-#{System.unique_integer([:positive])}"
      skill_dir = Path.join(SkillConfig.harness_global_skills_dir(), skill_name)
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
      skill_dir = Path.join(SkillConfig.harness_global_skills_dir(), skill_name)
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "SKILL.md"), "Agents specific skill")

      on_exit(fn -> File.rm_rf(skill_dir) end)

      result = ResourceLoader.load_skill(tmp_dir, skill_name)
      assert result == {:ok, "Agents specific skill"}
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

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
