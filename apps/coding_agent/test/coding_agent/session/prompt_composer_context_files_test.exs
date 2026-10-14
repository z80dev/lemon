defmodule CodingAgent.Session.PromptComposerContextFilesTest do
  # Redirects HOME and LEMON_AGENT_DIR, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias CodingAgent.Session.PromptComposer

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous =
      for key <- ~w(HOME LEMON_AGENT_DIR COPILOT_HOME), into: %{}, do: {key, System.get_env(key)}

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))
    System.delete_env("COPILOT_HOME")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    {:ok, home: home}
  end

  test "the composed prompt includes every context-file and rule source", %{
    tmp_dir: tmp_dir,
    home: home
  } do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)

    context_files = %{
      "AGENTS.md" => "ctx-root-agents",
      "CLAUDE.md" => "ctx-root-claude",
      "GEMINI.md" => "ctx-root-gemini",
      "CLAUDE.local.md" => "ctx-root-claude-local @docs/imported.md",
      "docs/imported.md" => "ctx-imported-doc",
      ".claude/CLAUDE.md" => "ctx-claude-dir",
      ".lemon/AGENTS.md" => "ctx-lemon-dir",
      ".gemini/GEMINI.md" => "ctx-gemini-dir",
      ".agents/AGENTS.md" => "ctx-agents-dir",
      ".agent/AGENTS.md" => "ctx-agent-dir",
      ".omp/AGENTS.md" => "ctx-omp-dir",
      ".github/copilot-instructions.md" => "ctx-copilot-project"
    }

    global_files = %{
      ".claude/CLAUDE.md" => "ctx-global-claude",
      ".gemini/GEMINI.md" => "ctx-global-gemini",
      ".codex/AGENTS.md" => "ctx-global-codex",
      ".config/opencode/AGENTS.md" => "ctx-global-opencode",
      ".agents/AGENTS.md" => "ctx-global-agents",
      ".agent/AGENTS.md" => "ctx-global-agent",
      ".copilot/copilot-instructions.md" => "ctx-global-copilot"
    }

    rule_files = %{
      ".cursor/rules/cursor.mdc" => "---\nalwaysApply: true\n---\nrule-cursor-body",
      ".cursorrules" => "rule-cursorrules-body",
      ".windsurf/rules/wind.md" => "---\ntrigger: always_on\n---\nrule-windsurf-body",
      ".windsurfrules" => "rule-windsurfrules-body",
      ".clinerules" => "rule-cline-body",
      ".github/instructions/all.instructions.md" =>
        "---\napplyTo: \"**/*\"\n---\nrule-github-body",
      ".agents/rules/agents.md" => "---\nalwaysApply: true\n---\nrule-agents-body",
      ".agent/rules/agent.mdc" => "---\nalwaysApply: true\n---\nrule-agent-body",
      ".lemon/rules/native.md" => "---\ndescription: Native rulebook entry\n---\nnative-hidden",
      ".github/instructions/ts.instructions.md" => "---\napplyTo: \"**/*.ts\"\n---\nts-hidden"
    }

    write_all(repo, context_files)
    write_all(home, global_files)
    write_all(repo, rule_files)

    write!(
      Path.join(home, ".codeium/windsurf/memories/global_rules.md"),
      "rule-windsurf-global-body"
    )

    prompt =
      PromptComposer.compose_system_prompt(repo, nil, nil, workspace_dir, :main, "", %{
        environment: "environment-block-marker"
      })

    expected =
      Enum.reject(Map.values(context_files), &String.contains?(&1, "@")) ++
        ["ctx-root-claude-local ctx-imported-doc"] ++
        Map.values(global_files) ++
        ~w(rule-cursor-body rule-cursorrules-body rule-windsurf-body rule-windsurfrules-body
           rule-cline-body rule-github-body rule-agents-body rule-agent-body
           rule-windsurf-global-body)

    for marker <- expected, do: assert(prompt =~ marker, marker)

    assert prompt =~ "- native: Native rulebook entry"
    assert prompt =~ Path.join(repo, ".lemon/rules/native.md")
    assert prompt =~ "- ts: GitHub Copilot instructions for **/*.ts"
    refute prompt =~ "native-hidden"
    refute prompt =~ "ts-hidden"

    assert offset(prompt, "ctx-global-claude") < offset(prompt, "ctx-root-agents")
    assert offset(prompt, "ctx-copilot-project") < offset(prompt, "## Always-apply rules")
    assert offset(prompt, "## Always-apply rules") < offset(prompt, "## Rulebook")
    assert offset(prompt, "## Rulebook") < offset(prompt, "environment-block-marker")

    sections =
      PromptComposer.compose_sections(repo, nil, nil, workspace_dir, :main, "", %{})

    rule_labels = sections |> Enum.map(& &1.label) |> Enum.filter(&(&1 =~ ~r/^(rule |Rulebook)/))
    assert "rule cursor (project)" in rule_labels
    assert "rule global_rules (global)" in rule_labels
    assert "Rulebook (2 rules)" in rule_labels
    refute Enum.any?(sections, &String.contains?(&1.label, tmp_dir))
  end

  defp write_all(root, files) do
    Enum.each(files, fn {rel, content} -> write!(Path.join(root, rel), content) end)
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp offset(text, marker), do: elem(:binary.match(text, marker), 0)
end
