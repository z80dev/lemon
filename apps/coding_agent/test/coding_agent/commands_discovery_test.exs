defmodule CodingAgent.CommandsDiscoveryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Commands

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    cwd = Path.join(tmp_dir, "project")
    home = Path.join(tmp_dir, "home")
    agent_dir = Path.join(tmp_dir, "agent")
    Enum.each([cwd, home, agent_dir], &File.mkdir_p!/1)

    previous = System.get_env("LEMON_AGENT_DIR")
    System.put_env("LEMON_AGENT_DIR", agent_dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_AGENT_DIR", previous),
        else: System.delete_env("LEMON_AGENT_DIR")
    end)

    %{cwd: cwd, home: home, agent_dir: agent_dir}
  end

  defp write(root, relative, content) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp names(cwd, home), do: cwd |> Commands.list(home: home) |> Enum.map(& &1.name)

  describe "project sources" do
    test "discovers every supported root and format", %{cwd: cwd, home: home} do
      write(cwd, ".lemon/command/legacy.md", "legacy")
      write(cwd, ".lemon/commands/native.md", "native")
      write(cwd, ".omp/commands/omp-cmd.md", "omp")
      write(cwd, ".agents/commands/agents-cmd.md", "agents")
      write(cwd, ".agent/commands/agent-cmd.md", "agent")
      write(cwd, ".claude/commands/top.md", "claude top")
      write(cwd, ".claude/commands/git/commit.md", "claude nested")
      write(cwd, ".claude/commands/a/b/c.md", "claude deep")
      write(cwd, ".codex/prompts/codex-prompt.md", "codex prompt")
      write(cwd, ".codex/commands/codex-cmd.md", "codex command")
      write(cwd, ".github/prompts/review.prompt.md", "github prompt")
      write(cwd, ".github/prompts/README.md", "not a prompt file")
      write(cwd, ".gemini/commands/explain.toml", ~s(prompt = "Explain {{args}}"))
      write(cwd, ".gemini/commands/git/fix.toml", ~s(prompt = "Fix it"))
      write(cwd, ".gemini/commands/broken.toml", ~s(description = "no prompt"))
      write(cwd, ".omp/commands/notes.txt", "ignored extension")
      write(cwd, ".claude/commands/.hidden.md", "ignored dotfile")

      assert names(cwd, home) == [
               "a:b:c",
               "agent-cmd",
               "agents-cmd",
               "codex-cmd",
               "codex-prompt",
               "explain",
               "git:commit",
               "git:fix",
               "legacy",
               "native",
               "omp-cmd",
               "review",
               "top"
             ]

      by_name = Map.new(Commands.list(cwd, home: home), &{&1.name, &1})
      assert by_name["git:commit"].source == "claude"
      assert by_name["git:commit"].scope == :project
      assert by_name["review"].source == "github"
      assert by_name["explain"].source == "gemini"
      assert by_name["explain"].template == "Explain {{args}}"
    end

    test "only the claude and gemini roots recurse", %{cwd: cwd, home: home} do
      write(cwd, ".omp/commands/sub/nested.md", "not discovered")
      write(cwd, ".codex/prompts/sub/nested.md", "not discovered")
      assert names(cwd, home) == []
    end

    test "parses markdown frontmatter fields", %{cwd: cwd, home: home} do
      write(cwd, ".claude/commands/commit.md", """
      ---
      description: "Commit staged work"
      argument-hint: [message]
      model: opus
      subtask: true
      ---

      Commit with message: $ARGUMENTS
      """)

      assert [command] = Commands.list(cwd, home: home)
      assert command.description == "Commit staged work"
      assert command.argument_hint == "[message]"
      assert command.model == "opus"
      assert command.subtask
      assert command.template == "Commit with message: $ARGUMENTS"
    end

    test "parses gemini description and CRLF markdown", %{cwd: cwd, home: home} do
      write(cwd, ".gemini/commands/plan.toml", """
      description = "Plan a change"
      prompt = \"\"\"
      Plan: {{args}}
      \"\"\"
      """)

      write(cwd, ".codex/prompts/crlf.md", "---\r\ndescription: Windows\r\n---\r\nBody\r\n")

      by_name = Map.new(Commands.list(cwd, home: home), &{&1.name, &1})
      assert by_name["plan"].description == "Plan a change"
      assert by_name["plan"].template == "Plan: {{args}}"
      assert by_name["crlf"].description == "Windows"
      assert by_name["crlf"].template == "Body"
    end

    test "skips oversized and whitespace-named files", %{cwd: cwd, home: home} do
      write(cwd, ".lemon/commands/huge.md", String.duplicate("x", 64 * 1024 + 1))
      write(cwd, ".lemon/commands/two words.md", "unreachable")
      write(cwd, ".lemon/commands/ok.md", "fine")
      assert names(cwd, home) == ["ok"]
    end
  end

  describe "global sources and precedence" do
    test "discovers user-global roots under the injected home", %{
      cwd: cwd,
      home: home,
      agent_dir: agent_dir
    } do
      write(agent_dir, "command/lemon-legacy.md", "a")
      write(agent_dir, "commands/lemon-global.md", "b")
      write(home, ".omp/agent/commands/omp-global.md", "c")
      write(home, ".agents/commands/agents-global.md", "d")
      write(home, ".claude/commands/team/claude-global.md", "e")
      write(home, ".codex/prompts/codex-global.md", "f")
      write(home, ".gemini/commands/gemini-global.toml", ~s(prompt = "g"))

      commands = Commands.list(cwd, home: home)

      assert Enum.map(commands, & &1.name) == [
               "agents-global",
               "codex-global",
               "gemini-global",
               "lemon-global",
               "lemon-legacy",
               "omp-global",
               "team:claude-global"
             ]

      assert Enum.all?(commands, &(&1.scope == :global))
    end

    test "project beats global and Lemon beats foreign roots", %{
      cwd: cwd,
      home: home,
      agent_dir: agent_dir
    } do
      write(home, ".claude/commands/shared.md", "global claude")
      write(agent_dir, "commands/shared.md", "global lemon")
      assert Commands.get(cwd, "shared", home: home).template == "global lemon"

      write(cwd, ".gemini/commands/shared.toml", ~s(prompt = "project gemini"))
      assert Commands.get(cwd, "shared", home: home).template == "project gemini"

      write(cwd, ".github/prompts/shared.prompt.md", "project github")
      assert Commands.get(cwd, "shared", home: home).template == "project github"

      write(cwd, ".codex/prompts/shared.md", "project codex")
      assert Commands.get(cwd, "shared", home: home).template == "project codex"

      write(cwd, ".claude/commands/shared.md", "project claude")
      assert Commands.get(cwd, "shared", home: home).template == "project claude"

      write(cwd, ".agents/commands/shared.md", "project agents")
      assert Commands.get(cwd, "shared", home: home).template == "project agents"

      write(cwd, ".omp/commands/shared.md", "project omp")
      assert Commands.get(cwd, "shared", home: home).template == "project omp"

      write(cwd, ".lemon/commands/shared.md", "project lemon")
      assert Commands.get(cwd, "shared", home: home).template == "project lemon"

      write(cwd, ".lemon/command/shared.md", "project lemon legacy")
      assert Commands.get(cwd, "shared", home: home).template == "project lemon legacy"

      assert [%{name: "shared", scope: :project}] = Commands.list(cwd, home: home)
    end
  end

  test "the control-plane projection omits templates and paths", %{cwd: cwd} do
    write(cwd, ".claude/commands/review.md", """
    ---
    description: Review
    argument-hint: <path>
    ---
    Secret template body
    """)

    assert CodingAgent.ControlPlaneProvider.slash_commands(cwd) == [
             %{name: "review", description: "Review", argument_hint: "<path>"}
           ]
  end

  describe "expand/2" do
    test "appends arguments when the template has no placeholder" do
      assert Commands.expand(%{template: "Review the diff."}, "carefully please") ==
               "Review the diff.\n\ncarefully please"

      assert Commands.expand(%{template: "Review the diff."}, "") == "Review the diff."
    end

    test "supports $@, {{args}} and quoted positional arguments" do
      template = "first=$1 second=$2 all=$@ gemini={{args}} spaced={{ args }}"

      assert Commands.expand(%{template: template}, ~s(one "two words")) ==
               ~s(first=one second=two words all=one "two words" gemini=one "two words" spaced=one "two words")
    end

    test "substitution is single pass" do
      assert Commands.expand(%{template: "$1 / $ARGUMENTS"}, "$2 $ARGUMENTS") ==
               "$2 / $2 $ARGUMENTS"
    end
  end

  describe "expand_input/3" do
    test "expands a matching command", %{cwd: cwd, home: home} do
      write(cwd, ".claude/commands/git/commit.md", "Commit: $ARGUMENTS")

      assert {:ok, "Commit: fix the bug", %{name: "git:commit"}} =
               Commands.expand_input(cwd, "  /git:commit fix the bug\n", home: home)

      assert {:ok, "Commit: ", _} = Commands.expand_input(cwd, "/git:commit", home: home)
    end

    test "leaves unknown commands, plain text and paths alone", %{cwd: cwd, home: home} do
      write(cwd, ".lemon/commands/usr.md", "never")
      assert :nomatch = Commands.expand_input(cwd, "/unknown arg", home: home)
      assert :nomatch = Commands.expand_input(cwd, "hello /usr", home: home)
      assert :nomatch = Commands.expand_input(cwd, "/usr/bin/env", home: home)
      assert :nomatch = Commands.expand_input(cwd, "/", home: home)
    end

    test "bounds the expanded prompt", %{cwd: cwd, home: home} do
      write(cwd, ".lemon/commands/boom.md", String.duplicate("$ARGUMENTS ", 100))
      args = String.duplicate("a", 4 * 1024)
      assert {:error, :too_large} = Commands.expand_input(cwd, "/boom " <> args, home: home)
    end
  end
end
