defmodule CodingAgent.RulesTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Rules
  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_home = System.get_env("HOME")
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    home = Path.join(tmp_dir, "home")
    agent_dir = Path.join(tmp_dir, "agent")
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(home)
    CodingAgent.TestGitRepo.init!(repo)
    # The stream-rule tests below use project rules; the operator allows them.
    File.mkdir_p!(Path.join(home, ".lemon"))

    File.write!(
      Path.join(home, ".lemon/config.toml"),
      "[rules]\nallow_project_stream_rules = [#{inspect(repo)}]\n"
    )

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
      assert rules["always"].stream_pattern == nil
      assert rules["always"].injection_limit == 1

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

  describe "stream_rules/1" do
    test "parses regex sources, limits, kebab-case keys and fallback frontmatter", %{repo: repo} do
      dir = Path.join(repo, ".lemon/rules")
      pattern = ~S(\bTODO\b)
      write!(Path.join(dir, "a-default.md"), "---\nstreamPattern: '#{pattern}'\n---\nNo TODOs")

      write!(
        Path.join(dir, "b-custom.mdc"),
        "---\nstream-pattern: '(?i)unsafe'\ninjection-limit: 3\n---\nUse safe code"
      )

      write!(
        Path.join(dir, "c-fallback.md"),
        "---\nglobs: *.ex\nstreamPattern: 'danger'\ninjectionLimit: 2\n---\nAvoid danger"
      )

      write!(
        Path.join(dir, "d-manual.md"),
        "---\ntrigger: manual\nstreamPattern: 'manual'\n---\nExplicit stream trigger"
      )

      write!(
        Path.join(dir, "disabled.md"),
        "---\nenabled: false\nstreamPattern: 'disabled'\n---\nDisabled body"
      )

      write!(Path.join(dir, "ordinary.md"), "---\nalwaysApply: true\n---\nOrdinary body")

      rules = Rules.stream_rules(repo)
      assert names(rules) == ["a-default", "b-custom", "c-fallback", "d-manual"]
      assert rules == Enum.filter(Rules.discover(repo), &(&1.stream_pattern != nil))
      rules = by_name(rules)

      assert rules["a-default"].stream_pattern == pattern
      assert rules["a-default"].content == "No TODOs"
      assert rules["a-default"].injection_limit == 1
      assert rules["b-custom"].stream_pattern == "(?i)unsafe"
      assert rules["b-custom"].injection_limit == 3
      assert rules["c-fallback"].stream_pattern == "danger"
      assert rules["c-fallback"].injection_limit == 2
      assert rules["c-fallback"].globs == ["*.ex"]
    end

    test "stream patterns override every prompt trigger without adding context", %{repo: repo} do
      files = [
        {".lemon/rules/always.md", "alwaysApply: true"},
        {".lemon/rules/described.md", "description: Stream-only description"},
        {".lemon/rules/glob.md", "globs: '*.ex'"},
        {".windsurf/rules/on.md", "trigger: always_on"},
        {".github/instructions/all.instructions.md", "applyTo: '**'"},
        {".github/instructions/bare.instructions.md", ""},
        {".cursorrules", ""}
      ]

      for {path, metadata} <- files do
        write!(
          Path.join(repo, path),
          "---\n#{metadata}\nstreamPattern: 'forbidden'\n---\nStream-only body"
        )
      end

      assert length(Rules.stream_rules(repo)) == length(files)
      assert Rules.buckets(Rules.discover(repo)) == %{always_apply: [], rulebook: []}
      assert Rules.sections(repo) == []
    end

    test "stream rules leave existing prompt sections byte-identical", %{repo: repo} do
      dir = Path.join(repo, ".lemon/rules")
      write!(Path.join(dir, "always.md"), "---\nalwaysApply: true\n---\nAlways body")
      write!(Path.join(dir, "book.md"), "---\ndescription: On demand\n---\nBook body")
      original = Rules.sections(repo)

      write!(
        Path.join(dir, "stream.md"),
        "---\nalwaysApply: true\ndescription: Never indexed\nstreamPattern: 'bad'\n---\nCorrection"
      )

      assert Rules.sections(repo) == original
    end

    test "invalid patterns fail closed instead of becoming prompt rules", %{repo: repo} do
      patterns = [
        "'('",
        "'(*UTF)bad'",
        "''",
        "'   '",
        "null",
        "true",
        "123",
        "['bad']",
        "{bad: value}"
      ]

      for {pattern, index} <- Enum.with_index(patterns) do
        write!(
          Path.join(repo, ".lemon/rules/invalid-#{index}.md"),
          "---\nstreamPattern: #{pattern}\nalwaysApply: true\ndescription: Hidden\n---\nHidden body"
        )
      end

      assert Rules.discover(repo) == []
      assert Rules.stream_rules(repo) == []
      assert Rules.sections(repo) == []
    end

    test "injection limits must be positive integers when supplied", %{repo: repo} do
      for {limit, index} <- Enum.with_index(["0", "-1", "1.5", "'2'", "null", "true", "[]"]) do
        write!(
          Path.join(repo, ".lemon/rules/invalid-#{index}.md"),
          "---\nstreamPattern: 'bad'\ninjectionLimit: #{limit}\nalwaysApply: true\n---\nHidden"
        )
      end

      assert Rules.discover(repo) == []
      assert Rules.stream_rules(repo) == []
      assert Rules.sections(repo) == []
    end

    test "name precedence applies before stream selection", %{repo: repo, agent_dir: agent_dir} do
      cwd = Path.join(repo, "pkg")

      write!(
        Path.join(agent_dir, "rules/shared.md"),
        "---\nalwaysApply: true\n---\nGlobal prompt"
      )

      write!(
        Path.join(repo, ".lemon/rules/shared.md"),
        "---\nstreamPattern: 'far'\n---\nFar correction"
      )

      write!(
        Path.join(cwd, ".lemon/rules/shared.md"),
        "---\nstreamPattern: 'near'\ninjectionLimit: 2\n---\nNear correction"
      )

      write!(
        Path.join(agent_dir, "rules/ordinary.md"),
        "---\nstreamPattern: 'global'\n---\nGlobal correction"
      )

      write!(
        Path.join(cwd, ".lemon/rules/ordinary.md"),
        "---\nalwaysApply: true\n---\nProject prompt"
      )

      assert [%{name: "shared", content: "Near correction", injection_limit: 2}] =
               Rules.stream_rules(cwd)

      assert %{always_apply: [%{name: "ordinary"}], rulebook: []} =
               Rules.buckets(Rules.discover(cwd))
    end

    test "invalid higher-priority stream rules still shadow lower-priority names", %{
      repo: repo,
      agent_dir: agent_dir
    } do
      write!(
        Path.join(agent_dir, "rules/shared.md"),
        "---\nalwaysApply: true\n---\nGlobal prompt"
      )

      write!(
        Path.join(repo, ".cursor/rules/shared.mdc"),
        "---\nstreamPattern: 'valid'\n---\nLower correction"
      )

      write!(
        Path.join(repo, ".lemon/rules/shared.md"),
        "---\nstreamPattern: '('\ndescription: Hidden\n---\nInvalid correction"
      )

      assert Rules.discover(repo) == []
      assert Rules.stream_rules(repo) == []
      assert Rules.sections(repo) == []
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

      assert rulebook.text =~
               "- css\n  Globs: *.css\n  File: #{glob_only}\n- db: Database migrations\n" <>
                 "  Globs: priv/repo/**/*.exs\n  File: #{book}"

      refute rulebook.text =~ "db body"
      refute Enum.any?(sections, &(&1.text =~ "orphan"))
    end
  end

  describe "frontmatter parsing" do
    # YamlElixir.read_from_string/1 calls Application.start(:yamerl) on every
    # read; inside Session init that deadlocked against the application
    # controller. With yamerl (and yaml_elixir) stopped, parsing must work and
    # leave them stopped, proving no Application.start/1 is in the path.
    test "parses .mdc frontmatter without starting yamerl", %{repo: repo} do
      on_exit(fn -> {:ok, _} = Application.ensure_all_started(:yaml_elixir) end)
      :ok = Application.stop(:yaml_elixir)
      :ok = Application.stop(:yamerl)

      write!(
        Path.join(repo, ".cursor/rules/ts.mdc"),
        "---\ndescription: TypeScript\nglobs: [\"*.ts\"]\nalwaysApply: false\n---\nts body"
      )

      write!(Path.join(repo, ".cursor/rules/loose.mdc"), "---\nglobs: *.ex\n---\nex body")

      rules = by_name(Rules.discover(repo))

      assert rules["ts"].description == "TypeScript"
      assert rules["ts"].globs == ["*.ts"]
      assert rules["loose"].globs == ["*.ex"]
      refute List.keymember?(Application.started_applications(), :yamerl, 0)
      refute List.keymember?(Application.started_applications(), :yaml_elixir, 0)
    end

    test "duplicate keys reject the rule, which still shadows its namesake", %{
      repo: repo,
      agent_dir: agent_dir
    } do
      write!(Path.join(agent_dir, "rules/dup.md"), "---\nalwaysApply: true\n---\nglobal body")

      write!(
        Path.join(repo, ".lemon/rules/dup.md"),
        "---\nalwaysApply: false\nalwaysApply: true\n---\nproject body"
      )

      write!(
        Path.join(repo, ".lemon/rules/kebab.md"),
        "---\nalways-apply: false\nalwaysApply: true\n---\nkebab body"
      )

      write!(
        Path.join(repo, ".lemon/rules/loose.md"),
        "---\nglobs: *.ts\nglobs: *.js\n---\nloose body"
      )

      log = capture_log(fn -> assert Rules.discover(repo) == [] end)

      assert log =~ "Ignored rule dup: duplicate frontmatter fields"
      assert log =~ "Ignored rule kebab: duplicate frontmatter fields"
      assert log =~ "Ignored rule loose: duplicate frontmatter fields"
    end

    test "oversized frontmatter is refused with a bounded error", %{repo: repo} do
      write!(
        Path.join(repo, ".lemon/rules/big.md"),
        "---\nalwaysApply: true\n# " <> String.duplicate("x", 16_384) <> "\n---\nbig body"
      )

      log = capture_log(fn -> assert Rules.discover(repo) == [] end)

      assert log =~ "Ignored rule big: frontmatter exceeds 16 KiB"
      refute log =~ "xxxx"
    end
  end

  describe "limits" do
    test "2,000 rule files are capped by count with a visible note", %{repo: repo} do
      dir = Path.join(repo, ".cursor/rules")
      File.mkdir_p!(dir)

      for i <- 1..2_000 do
        name = "r" <> String.pad_leading(Integer.to_string(i), 4, "0")
        File.write!(Path.join(dir, name <> ".mdc"), "---\ndescription: rule #{i}\n---\nbody")
      end

      sections = Rules.sections(repo)

      assert Enum.map(sections, & &1.label) == ["Rulebook (256 rules)", "Rule limit"]
      assert List.last(sections).text =~ "only the first 256 rule files were loaded"
      assert length(Rules.discover(repo)) == 256
    end

    test "a 1 MiB always-apply body is truncated at the per-file cap", %{repo: repo} do
      path = Path.join(repo, ".lemon/rules/big.md")
      write!(path, "---\nalwaysApply: true\n---\nbig head\n" <> String.duplicate("y", 1_048_576))

      {sections, log} = with_log(fn -> Rules.sections(repo) end)
      [_header, %{label: "rule big (project)", text: text}] = sections

      assert text =~ "big head"
      assert text =~ "[... rule truncated at 64 KiB; read #{path} for the rest]"
      assert byte_size(text) < 64 * 1024 + 2048
      assert log =~ "Truncated prompt source"
    end

    test "always-apply bodies share one budget; descriptions are one bounded line", %{
      repo: repo
    } do
      for name <- ~w(a b c) do
        write!(
          Path.join(repo, ".lemon/rules/#{name}.md"),
          "---\nalwaysApply: true\n---\n" <> String.duplicate(name, 60 * 1024)
        )
      end

      write!(
        Path.join(repo, ".lemon/rules/book.md"),
        "---\ndescription: |\n  first line\n  second #{String.duplicate("d", 400)}\n---\nbody"
      )

      [_header, a, b, c, rulebook] = Rules.sections(repo)
      c_path = Path.join(repo, ".lemon/rules/c.md")

      assert a.text =~ String.duplicate("a", 60 * 1024)
      assert b.text =~ String.duplicate("b", 60 * 1024)
      assert c.text =~ "[... rule truncated: the 128 KiB always-apply rule budget is exhausted"
      assert c.text =~ "read #{c_path} for the rest]"
      assert byte_size(a.text <> b.text <> c.text) < 128 * 1024 + 1024

      [entry_head | _] = rulebook.text |> String.split("\n") |> Enum.drop(2)
      assert entry_head =~ "- book: first line second ddd"
      assert String.length(entry_head) == String.length("- book: ") + 300
      assert String.ends_with?(entry_head, "…")
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
