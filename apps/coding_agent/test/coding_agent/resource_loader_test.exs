defmodule CodingAgent.ResourceLoaderTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ResourceLoader

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

  describe "instruction_sections/1" do
    test "loads CLAUDE.md from cwd", %{tmp_dir: tmp_dir} do
      claude_path = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(claude_path, "# Project Instructions\nDo good things.")

      result = Enum.map_join(ResourceLoader.instruction_sections(tmp_dir), "\n\n", & &1.text)
      assert result =~ "# Project Instructions"
      assert result =~ "Do good things."
      assert result =~ "<!-- From: #{claude_path} -->"
    end

    test "loads from .claude subdirectory", %{tmp_dir: tmp_dir} do
      claude_dir = Path.join(tmp_dir, ".claude")
      File.mkdir_p!(claude_dir)
      File.write!(Path.join(claude_dir, "CLAUDE.md"), "Hidden claude config")

      result = Enum.map_join(ResourceLoader.instruction_sections(tmp_dir), "\n\n", & &1.text)
      assert result =~ "Hidden claude config"
    end

    test "loads from .lemon subdirectory", %{tmp_dir: tmp_dir} do
      lemon_dir = Path.join(tmp_dir, ".lemon")
      File.mkdir_p!(lemon_dir)
      File.write!(Path.join(lemon_dir, "CLAUDE.md"), "Lemon config")

      result = Enum.map_join(ResourceLoader.instruction_sections(tmp_dir), "\n\n", & &1.text)
      assert result =~ "Lemon config"
    end

    test "combines multiple instruction files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "Root config")
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "Agent config")

      result = Enum.map_join(ResourceLoader.instruction_sections(tmp_dir), "\n\n", & &1.text)
      assert result =~ "Root config"
      assert result =~ "Agent config"
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

      sections = ResourceLoader.instruction_sections(cwd)

      offsets =
        Enum.map(paths, fn path ->
          Enum.find_index(sections, &String.contains?(&1.text, "<!-- From: #{path} -->"))
        end)

      assert Enum.all?(offsets, &is_integer/1)
      assert offsets == Enum.sort(offsets)
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

      refute Enum.map_join(ResourceLoader.instruction_sections(cwd), "\n\n", & &1.text) =~
               "stray-"
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

      rendered = Enum.map_join(ResourceLoader.instruction_sections(cwd), "\n\n", & &1.text)
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

      sections = ResourceLoader.instruction_sections(cwd, foreign_globals: true)

      for i <- 0..(length(globals) - 1) do
        section = Enum.find(sections, &(&1.text =~ "global-#{i}"))
        assert section.label =~ "(global)"
        assert section.text =~ "Scope: global"
      end

      rendered =
        Enum.map_join(
          ResourceLoader.instruction_sections(cwd, foreign_globals: true),
          "\n\n",
          & &1.text
        )

      assert offset(rendered, "global-7") < offset(rendered, "project-directive")
    end

    test "COPILOT_HOME relocates the Copilot user instructions", %{tmp_dir: tmp_dir, home: home} do
      cwd = Path.join(tmp_dir, "project")
      File.mkdir_p!(cwd)
      copilot_home = Path.join(tmp_dir, "copilot-config")
      write!(Path.join(copilot_home, "copilot-instructions.md"), "relocated-copilot")
      write!(Path.join(home, ".copilot/copilot-instructions.md"), "default-copilot")
      System.put_env("COPILOT_HOME", copilot_home)

      rendered =
        Enum.map_join(
          ResourceLoader.instruction_sections(cwd, foreign_globals: true),
          "\n\n",
          & &1.text
        )

      assert rendered =~ "relocated-copilot"
      refute rendered =~ "default-copilot"
    end

    test "expands @imports relative to each instruction file, inside the repository", %{
      tmp_dir: tmp_dir,
      home: home
    } do
      cwd = Path.join(tmp_dir, "project")
      CodingAgent.TestGitRepo.init!(cwd)
      write!(Path.join(cwd, ".github/copilot-instructions.md"), "Style: @style.md")
      write!(Path.join(cwd, ".github/style.md"), "imported-style")
      write!(Path.join(cwd, "AGENTS.md"), "Personal: @~/notes.md\n`@style.md` stays")
      write!(Path.join(home, "notes.md"), "imported-home-note")
      write!(Path.join(cwd, "style.md"), "inline-code-must-not-expand")
      write!(Path.join(home, ".lemon/AGENTS.md"), "Global: @~/notes.md")

      rendered = Enum.map_join(ResourceLoader.instruction_sections(cwd), "\n\n", & &1.text)
      style = Path.join(cwd, ".github/style.md")
      assert rendered =~ "Style: <!-- @import #{style} -->imported-style<!-- /@import -->"
      refute rendered =~ "inline-code-must-not-expand"
      # Project files never import outside the repository; home-owned globals do.
      assert rendered =~ "Personal: @~/notes.md"
      assert rendered =~ "Global: <!-- @import #{Path.join(home, "notes.md")} -->"
      assert rendered =~ "`@style.md` stays"
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

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
