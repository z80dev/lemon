defmodule CodingAgent.RulesTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Rules

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("HOME")
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    home = Path.join(tmp_dir, "home")
    agent_dir = Path.join(tmp_dir, "agent")
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(Path.join(repo, ".git"))
    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", agent_dir)

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("LEMON_AGENT_DIR", previous_agent_dir)
    end)

    {:ok, home: home, agent_dir: agent_dir, repo: repo}
  end

  describe "discover/1 project sources" do
    test "cursor rules: frontmatter variants, nesting and unquoted globs", %{repo: repo} do
      rules_dir = Path.join(repo, ".cursor/rules")

      write!(Path.join(rules_dir, "always.mdc"), "---\nalwaysApply: true\n---\nalways body")

      write!(
        Path.join(rules_dir, "nested/typescript.mdc"),
        "---\ndescription:\nglobs: *.ts,src/**/*.{ts,tsx}\nalwaysApply: false\n---\nts body"
      )

      write!(
        Path.join(rules_dir, "described.md"),
        "---\ndescription: Use for APIs\n---\napi body"
      )

      write!(Path.join(rules_dir, "manual.mdc"), "---\ndescription:\nglobs:\n---\nmanual body")

      write!(
        Path.join(rules_dir, "disabled.mdc"),
        "---\nenabled: false\nalwaysApply: true\n---\nnope"
      )

      write!(Path.join(rules_dir, "notes.txt"), "not a rule")
      write!(Path.join(repo, ".cursorrules"), "legacy cursor body")

      rules = by_name(Rules.discover(repo))

      assert rules["always"].always_apply
      assert rules["always"].content == "always body"
      assert rules["always"].path == Path.join(rules_dir, "always.mdc")
      assert rules["always"].level == :project

      ts = rules["nested/typescript"]
      refute ts.always_apply
      assert ts.description == nil
      assert ts.globs == ["*.ts", "src/**/*.{ts,tsx}"]

      assert rules["described"].description == "Use for APIs"
      assert rules["manual"].globs == []
      refute Map.has_key?(rules, "disabled")
      refute Map.has_key?(rules, "notes")

      assert rules["cursorrules"].always_apply
      assert rules["cursorrules"].content == "legacy cursor body"

      %{always_apply: always, rulebook: rulebook} = Rules.buckets(Rules.discover(repo))
      assert names(always) == ["always", "cursorrules"]
      assert names(rulebook) == ["described", "nested/typescript"]
    end

    test "windsurf triggers and legacy .windsurfrules", %{repo: repo} do
      rules_dir = Path.join(repo, ".windsurf/rules")
      write!(Path.join(rules_dir, "on.md"), "---\ntrigger: always_on\n---\non body")
      write!(Path.join(rules_dir, "glob.md"), "---\ntrigger: glob\nglobs: *.py\n---\npy body")

      write!(
        Path.join(rules_dir, "model.md"),
        "---\ntrigger: model_decision\ndescription: When writing SQL\n---\nsql body"
      )

      write!(
        Path.join(rules_dir, "manual.md"),
        "---\ntrigger: manual\ndescription: Only on request\n---\nmanual body"
      )

      write!(Path.join(rules_dir, "ignored.mdc"), "---\nalwaysApply: true\n---\nmdc not read")
      write!(Path.join(repo, ".windsurfrules"), "legacy windsurf body")

      %{always_apply: always, rulebook: rulebook} = Rules.buckets(Rules.discover(repo))
      assert names(always) == ["on", "windsurfrules"]
      assert names(rulebook) == ["glob", "model"]
      assert Enum.find(rulebook, &(&1.name == "glob")).globs == ["*.py"]
    end

    test ".clinerules as a single file always applies", %{repo: repo} do
      write!(Path.join(repo, ".clinerules"), "cline body")

      assert [%{name: "clinerules", always_apply: true, content: "cline body"}] =
               Rules.discover(repo)
    end

    test "the nearest .clinerules directory provides markdown rules", %{repo: repo} do
      cwd = Path.join(repo, "pkg")
      File.mkdir_p!(cwd)
      write!(Path.join(repo, ".clinerules/style.md"), "---\nalwaysApply: true\n---\ncline style")
      write!(Path.join(repo, ".clinerules/skip.mdc"), "---\nalwaysApply: true\n---\nskip")

      assert [%{name: "style", always_apply: true}] = Rules.discover(cwd)
    end

    test "GitHub instructions map applyTo onto globs and always-apply", %{repo: repo} do
      dir = Path.join(repo, ".github/instructions")
      write!(Path.join(dir, "all.instructions.md"), "---\napplyTo: \"**\"\n---\nall body")

      write!(
        Path.join(dir, "frontend/ts.instructions.md"),
        "---\napplyTo: \"**/*.ts,**/*.tsx\"\n---\nts body"
      )

      write!(Path.join(dir, "bare.instructions.md"), "bare body")
      write!(Path.join(dir, "README.md"), "not an instruction file")

      rules = by_name(Rules.discover(repo))
      assert rules["all"].always_apply
      assert rules["all"].globs == []

      ts = rules["frontend/ts"]
      refute ts.always_apply
      assert ts.globs == ["**/*.ts", "**/*.tsx"]
      assert ts.description == "GitHub Copilot instructions for **/*.ts, **/*.tsx"

      assert rules["bare"].description == "GitHub Copilot instructions without applyTo metadata"
      refute Map.has_key?(rules, "README")

      %{always_apply: always, rulebook: rulebook} = Rules.buckets(Map.values(rules))
      assert names(always) == ["all"]
      assert Enum.sort(names(rulebook)) == ["bare", "frontend/ts"]
    end

    test ".lemon and .agent(s) rules walk ancestors up to the Git root", %{
      tmp_dir: tmp_dir,
      repo: repo
    } do
      cwd = Path.join(repo, "apps/web")
      File.mkdir_p!(cwd)
      write!(Path.join(repo, ".lemon/rules/native.md"), "---\nalways-apply: true\n---\nnative")
      write!(Path.join(cwd, ".agents/rules/agents.mdc"), "---\nglobs: [\"*.ex\"]\n---\nagents")
      write!(Path.join(repo, ".agent/rules/agent.md"), "---\ndescription: Agent rule\n---\nagent")
      write!(Path.join(tmp_dir, ".lemon/rules/outside.md"), "---\nalwaysApply: true\n---\nout")
      # cwd-only sources are not read from ancestors.
      write!(Path.join(repo, ".cursor/rules/root-cursor.mdc"), "---\nalwaysApply: true\n---\nc")

      rules = by_name(Rules.discover(cwd))
      assert Map.keys(rules) |> Enum.sort() == ["agent", "agents", "native"]
      assert rules["native"].always_apply
      assert rules["agents"].globs == ["*.ex"]
    end

    test "nearer directories win over farther ones for the same name", %{repo: repo} do
      cwd = Path.join(repo, "pkg")
      write!(Path.join(repo, ".lemon/rules/style.md"), "---\nalwaysApply: true\n---\nfar")
      write!(Path.join(cwd, ".lemon/rules/style.md"), "---\nalwaysApply: true\n---\nnear")

      assert [%{name: "style", content: "near"}] = Rules.discover(cwd)
    end
  end

  describe "discover/1 global sources" do
    test "reads agent dir, ~/.agent(s)/rules and Windsurf global rules", %{
      repo: repo,
      home: home,
      agent_dir: agent_dir
    } do
      write!(Path.join(agent_dir, "rules/lemon-global.md"), "---\nalwaysApply: true\n---\nlg")
      write!(Path.join(home, ".agents/rules/agents-global.mdc"), "---\nglobs: \"*.rb\"\n---\nag")
      write!(Path.join(home, ".agent/rules/agent-global.md"), "---\ndescription: d\n---\nag2")
      write!(Path.join(home, ".codeium/windsurf/memories/global_rules.md"), "windsurf global")

      rules = by_name(Rules.discover(repo))

      assert Enum.sort(Map.keys(rules)) ==
               ["agent-global", "agents-global", "global_rules", "lemon-global"]

      assert Enum.all?(Map.values(rules), &(&1.level == :global))
      assert rules["global_rules"].always_apply
      assert rules["agents-global"].globs == ["*.rb"]
    end

    test "the home directory is not walked as a project directory", %{home: home} do
      cwd = Path.join(home, "work")
      File.mkdir_p!(cwd)
      write!(Path.join(home, ".lemon/rules/home-native.md"), "---\nalwaysApply: true\n---\nh")

      assert Rules.discover(cwd) == []
    end

    test "project rules shadow global rules; disabled rules do not", %{
      repo: repo,
      agent_dir: agent_dir
    } do
      write!(Path.join(agent_dir, "rules/shared.md"), "---\nalwaysApply: true\n---\nglobal")
      write!(Path.join(repo, ".lemon/rules/shared.md"), "---\nalwaysApply: true\n---\nproject")
      write!(Path.join(agent_dir, "rules/toggled.md"), "---\nalwaysApply: true\n---\nglobal on")
      write!(Path.join(repo, ".lemon/rules/toggled.md"), "---\nenabled: false\n---\nproject off")

      rules = by_name(Rules.discover(repo))
      assert rules["shared"].content == "project"
      assert rules["shared"].level == :project
      assert rules["toggled"].content == "global on"
    end
  end

  describe "sections/1" do
    test "renders always-apply bodies and a rulebook index with paths", %{
      repo: repo,
      agent_dir: agent_dir
    } do
      write!(Path.join(repo, ".lemon/rules/b-always.md"), "---\nalwaysApply: true\n---\nbody B")
      write!(Path.join(agent_dir, "rules/a-always.md"), "---\nalwaysApply: true\n---\nbody A")

      book = Path.join(repo, ".cursor/rules/db.mdc")

      write!(
        book,
        "---\ndescription: Database migrations\nglobs: [\"priv/repo/**/*.exs\"]\n---\ndb body"
      )

      glob_only = Path.join(repo, ".cursor/rules/css.mdc")
      write!(glob_only, "---\nglobs: \"*.css\"\n---\ncss body")
      write!(Path.join(repo, ".cursor/rules/orphan.mdc"), "orphan body")

      sections = Rules.sections(repo)
      assert sections == Rules.sections(repo)

      assert Enum.map(sections, & &1.label) == [
               "Always-apply rules",
               "rule a-always (global)",
               "rule b-always (project)",
               "Rulebook (2 rules)"
             ]

      assert Enum.map(sections, & &1.category) ==
               [:system_prompt, :context_files, :context_files, :context_files]

      [_header, a, _b, rulebook] = sections
      assert a.text =~ "body A"
      assert a.text =~ Path.join(agent_dir, "rules/a-always.md")

      assert rulebook.text =~ "## Rulebook"
      assert rulebook.text =~ "`read` the rule file"

      assert rulebook.text =~
               "- css\n  Globs: *.css\n  File: #{glob_only}\n- db: Database migrations\n" <>
                 "  Globs: priv/repo/**/*.exs\n  File: #{book}"

      refute rulebook.text =~ "db body"
      refute Enum.any?(sections, &(&1.text =~ "orphan"))
    end

    test "no rules renders no sections", %{repo: repo} do
      assert Rules.sections(repo) == []
    end
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp by_name(rules), do: Map.new(rules, &{&1.name, &1})
  defp names(rules), do: Enum.map(rules, & &1.name)

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
