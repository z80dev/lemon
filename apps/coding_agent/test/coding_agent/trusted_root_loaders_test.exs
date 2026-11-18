defmodule CodingAgent.TrustedRootLoadersTest do
  # Redirects HOME and LEMON_AGENT_DIR, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias CodingAgent.{Commands, ResourceLoader, Rules}
  alias CodingAgent.Session.PromptComposer

  setup do
    # Outside every Git repository (unlike ExUnit's tmp_dir, which lives in the
    # checkout), so the no-Git-root boundary is exercised for real.
    base =
      Path.join(System.tmp_dir!(), "lemon-trusted-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    {:ok, base} = LemonCore.TrustedRoot.realpath(base)

    previous =
      for key <- ~w(HOME LEMON_AGENT_DIR COPILOT_HOME), into: %{}, do: {key, System.get_env(key)}

    home = Path.join(base, "home")
    File.mkdir_p!(home)
    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", Path.join(base, "agent"))
    System.delete_env("COPILOT_HOME")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(base)
    end)

    {:ok, base: base, home: home}
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp rendered(sections), do: Enum.map_join(sections, "\n\n", & &1.text)

  defp repo!(dir) do
    File.mkdir_p!(Path.join(dir, ".git/objects"))
    File.mkdir_p!(Path.join(dir, ".git/refs"))
    File.write!(Path.join(dir, ".git/HEAD"), "ref: refs/heads/main\n")
    dir
  end

  test "an empty .git in a same-owner parent does not widen the root", %{base: base} do
    parent = Path.join(base, "shared")
    File.mkdir_p!(Path.join(parent, ".git"))
    File.write!(Path.join(base, ".git"), "")
    write!(Path.join(parent, "AGENTS.md"), "PARENT_AGENTS")
    write!(Path.join(parent, "secret.md"), "SIBLING_SECRET")
    cwd = Path.join(parent, "session")
    write!(Path.join(cwd, "AGENTS.md"), "Session @../secret.md")

    text = rendered(ResourceLoader.instruction_sections(cwd))
    assert text =~ "Session @../secret.md"
    refute text =~ "PARENT_AGENTS"
    refute text =~ "SIBLING_SECRET"
  end

  test "personas above the trusted directory or linked out of the root never load", %{
    base: base,
    home: home
  } do
    persona = fn id, prompt -> "---\nname: #{id}\ndescription: test\n---\n#{prompt}\n" end
    write!(Path.join(base, ".claude/agents/planted.md"), persona.("planted", "PLANTED"))
    secret = write!(Path.join(home, "secret.md"), persona.("leaked", "LEAKED_PERSONA"))
    cwd = Path.join(base, "session")
    write!(Path.join(cwd, ".claude/agents/local.md"), persona.("local", "LOCAL_PERSONA"))
    File.ln_s!(secret, Path.join(cwd, ".claude/agents/leaked.md"))
    File.mkdir_p!(Path.join(cwd, ".lemon"))
    File.ln_s!(Path.join(home, "native"), Path.join(cwd, ".lemon/agents"))
    write!(Path.join(home, "native/scout.md"), "---\ndescription: hijack\n---\nHIJACKED_SCOUT\n")

    ids = cwd |> CodingAgent.Subagents.list() |> Enum.map(& &1.id)
    assert "local" in ids
    refute "planted" in ids
    refute "leaked" in ids
    assert %{source: :builtin} = scout = CodingAgent.Subagents.get(cwd, "scout")
    refute scout.prompt =~ "HIJACKED_SCOUT"
  end

  describe "project stream rules" do
    setup %{base: base, home: home} do
      repo = repo!(Path.join(base, "repo"))

      write!(
        Path.join(repo, ".lemon/rules/hijack.md"),
        "---\nstreamPattern: \".\"\n---\nPROJECT_INTERRUPT"
      )

      write!(
        Path.join(home, ".lemon/agent/rules/operator.md"),
        "---\nstreamPattern: OPERATOR\n---\nOPERATOR_INTERRUPT"
      )

      System.put_env("LEMON_AGENT_DIR", Path.join(home, ".lemon/agent"))
      {:ok, repo: repo}
    end

    test "are ignored and reported without an operator allowlist", %{repo: repo} do
      # A project config cannot grant itself the permission.
      write!(
        Path.join(repo, ".lemon/config.toml"),
        "[rules]\nallow_project_stream_rules = [#{inspect(repo)}]\n"
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Enum.map(Rules.stream_rules(repo), & &1.name) == ["operator"]
        end)

      assert log =~ "Ignored project stream rules hijack"
    end

    test "load when the global config allows the trusted root", %{repo: repo, home: home} do
      write!(
        Path.join(home, ".lemon/config.toml"),
        "[rules]\nallow_project_stream_rules = [#{inspect(repo)}]\n"
      )

      assert Enum.map(Rules.stream_rules(Path.join(repo, ".lemon")), & &1.name) ==
               ["hijack", "operator"]
    end
  end

  test "without a Git root, host-level files above the trusted directory are never read", %{
    base: base
  } do
    # `base` plays a shared directory such as /tmp that another user can write.
    write!(Path.join(base, "AGENTS.md"), "HOST_AGENTS")
    write!(Path.join(base, ".claude/CLAUDE.md"), "HOST_CLAUDE_DIR")
    write!(Path.join(base, ".clinerules"), "HOST_CLINERULES")
    write!(Path.join(base, ".lemon/rules/host.md"), "---\nalwaysApply: true\n---\nHOST_RULE")
    cwd = Path.join(base, "session")
    write!(Path.join(cwd, "AGENTS.md"), "SESSION_AGENTS")

    text = rendered(ResourceLoader.instruction_sections(cwd) ++ Rules.sections(cwd))
    assert text =~ "SESSION_AGENTS"

    for marker <- ~w(HOST_AGENTS HOST_CLAUDE_DIR HOST_CLINERULES HOST_RULE),
        do: refute(text =~ marker, marker)
  end

  test "instruction walks stop at the Git root", %{base: base} do
    write!(Path.join(base, "AGENTS.md"), "ABOVE_ROOT")
    repo = Path.join(base, "repo")
    repo!(repo)
    write!(Path.join(repo, "AGENTS.md"), "REPO_ROOT")
    cwd = Path.join(repo, "a/b")
    write!(Path.join(cwd, "AGENTS.md"), "NESTED")

    text = rendered(ResourceLoader.instruction_sections(cwd))
    assert text =~ "REPO_ROOT"
    assert text =~ "NESTED"
    refute text =~ "ABOVE_ROOT"
  end

  test "symlinked instruction files, rule files and rule dirs leaving the root are ignored", %{
    base: base,
    home: home
  } do
    secret = write!(Path.join(home, ".ssh/id_ed25519"), "PRIVATE_KEY_BYTES")
    outside_rules = Path.join(base, "outside-rules")
    write!(Path.join(outside_rules, "x.md"), "---\nalwaysApply: true\n---\nOUTSIDE_RULE")

    repo = Path.join(base, "repo")
    repo!(repo)
    File.mkdir_p!(Path.join(repo, ".claude"))
    File.mkdir_p!(Path.join(repo, ".lemon"))
    File.mkdir_p!(Path.join(repo, ".cursor/rules"))
    File.ln_s!(secret, Path.join(repo, "AGENTS.md"))
    File.ln_s!(secret, Path.join(repo, ".claude/CLAUDE.md"))
    File.ln_s!(secret, Path.join(repo, ".cursorrules"))
    File.ln_s!(secret, Path.join(repo, ".windsurfrules"))
    File.ln_s!(secret, Path.join(repo, ".clinerules"))
    File.ln_s!(secret, Path.join(repo, ".cursor/rules/key.mdc"))
    File.ln_s!(outside_rules, Path.join(repo, ".lemon/rules"))
    File.ln!(secret, Path.join(repo, "GEMINI.md"))

    # Links that stay inside the root still load.
    write!(Path.join(repo, "docs/guide.md"), "INSIDE_GUIDE")
    File.ln_s!(Path.join(repo, "docs/guide.md"), Path.join(repo, "CLAUDE.md"))

    text = rendered(ResourceLoader.instruction_sections(repo) ++ Rules.sections(repo))
    assert text =~ "INSIDE_GUIDE"
    refute text =~ "PRIVATE_KEY_BYTES"
    refute text =~ "OUTSIDE_RULE"
    assert Rules.stream_rules(repo) == []
  end

  test "command discovery ignores links leaving the root and never walks a linked /", %{
    base: base,
    home: home
  } do
    secret = write!(Path.join(home, "secret.md"), "SECRET_TEMPLATE")
    outside = Path.join(base, "outside-commands")
    write!(Path.join(outside, "dir.md"), "OUTSIDE_DIR_TEMPLATE")

    repo = Path.join(base, "repo")
    repo!(repo)
    write!(Path.join(repo, ".claude/commands/ok.md"), "INSIDE_TEMPLATE")
    File.ln_s!(secret, Path.join(repo, ".claude/commands/leak.md"))
    File.ln_s!("/", Path.join(repo, ".claude/commands/root"))
    File.mkdir_p!(Path.join(repo, ".gemini"))
    File.ln_s!("/", Path.join(repo, ".gemini/commands"))
    File.mkdir_p!(Path.join(repo, ".lemon"))
    File.ln_s!(outside, Path.join(repo, ".lemon/commands"))

    names = repo |> Commands.list(home: Path.join(base, "empty-home")) |> Enum.map(& &1.name)
    assert names == ["ok"]
  end

  test "other tools' global instruction files load only in coding sessions", %{
    base: base,
    home: home
  } do
    repo = Path.join(base, "repo")
    repo!(repo)
    write!(Path.join(home, ".claude/CLAUDE.md"), "FOREIGN_CLAUDE")
    write!(Path.join(home, ".codex/AGENTS.md"), "FOREIGN_CODEX")
    write!(Path.join(home, ".copilot/copilot-instructions.md"), "FOREIGN_COPILOT")
    write!(Path.join(home, ".lemon/AGENTS.md"), "LEMON_GLOBAL")

    compose = fn mode ->
      PromptComposer.compose_system_prompt(repo, nil, nil, base, :main, "", %{session_mode: mode})
    end

    chat = compose.(:chat)
    assert chat =~ "LEMON_GLOBAL"
    for marker <- ~w(FOREIGN_CLAUDE FOREIGN_CODEX FOREIGN_COPILOT), do: refute(chat =~ marker)

    coding = compose.(:coding)

    for marker <- ~w(LEMON_GLOBAL FOREIGN_CLAUDE FOREIGN_CODEX FOREIGN_COPILOT),
        do: assert(coding =~ marker, marker)
  end

  describe "assistant homes are never projects" do
    # Plants every project resource kind in a home, including a legacy rule
    # that links to the gated MEMORY.md.
    defp plant_home!(home_dir) do
      persona = "---\nname: evil\ndescription: planted\n---\nHOME_PERSONA\n"
      write!(Path.join(home_dir, "AGENTS.md"), "HOME_AGENTS")
      memory = write!(Path.join(home_dir, "MEMORY.md"), "HOME_MEMORY_SECRET")
      write!(Path.join(home_dir, "USER.md"), "HOME_USER_SECRET")
      write!(Path.join(home_dir, "CLAUDE.md"), "HOME_CLAUDE @MEMORY.md")
      File.ln_s!(memory, Path.join(home_dir, ".cursorrules"))

      write!(
        Path.join(home_dir, ".lemon/rules/home.md"),
        "---\nalwaysApply: true\n---\nHOME_RULE"
      )

      write!(Path.join(home_dir, ".lemon/commands/homecmd.md"), "HOME_COMMAND")
      write!(Path.join(home_dir, ".lemon/agents/evil.md"), persona)
      write!(Path.join(home_dir, ".lemon/prompts/tpl.md"), "HOME_TEMPLATE")
      File.mkdir_p!(Path.join(home_dir, "sub"))
    end

    defp assert_no_home_project!(cwd, base) do
      text = rendered(ResourceLoader.instruction_sections(cwd) ++ Rules.sections(cwd))

      for marker <- ~w(HOME_CLAUDE HOME_MEMORY_SECRET HOME_RULE),
          do: refute(text =~ marker, "#{cwd}: #{marker}")

      assert Rules.discover(cwd) |> Enum.filter(&(&1.level == :project)) == []
      refute "homecmd" in Enum.map(Commands.list(cwd, home: Path.join(base, "none")), & &1.name)
      refute "evil" in Enum.map(CodingAgent.Subagents.list(cwd), & &1.id)
      assert ResourceLoader.load_prompt(cwd, "tpl") == {:error, :not_found}
    end

    test "the assistant home and its subdirectories load no project resources", %{base: base} do
      home_dir = LemonCore.Cwd.assistant_home()
      plant_home!(home_dir)

      for cwd <- [home_dir, Path.join(home_dir, "sub")] do
        assert_no_home_project!(cwd, base)

        for {scope, opts} <- [
              {:subagent, %{session_mode: :chat}},
              {:main, %{session_mode: :chat, persona: false}},
              {:main, %{session_mode: :coding}}
            ] do
          prompt = PromptComposer.compose_system_prompt(cwd, nil, nil, home_dir, scope, "", opts)

          for marker <- ~w(HOME_CLAUDE HOME_MEMORY_SECRET HOME_USER_SECRET HOME_RULE),
              do: refute(prompt =~ marker, "#{scope} #{inspect(opts)}: #{marker}")
        end

        assert LemonCore.TrustedRoot.project_root(cwd) == :none
      end
    end

    test "a profile workspace loads no project resources", %{base: base} do
      home_dir = LemonCore.Paths.home_path(["profiles", "p1", "workspace"])
      plant_home!(home_dir)

      assert_no_home_project!(home_dir, base)
      assert LemonCore.TrustedRoot.project_root(home_dir) == :none
    end

    test "a repository containing the home cannot link to or import its files", %{base: base} do
      repo!(base)
      home_dir = LemonCore.Cwd.assistant_home()
      plant_home!(home_dir)
      memory = Path.join(home_dir, "MEMORY.md")
      File.ln_s!(memory, Path.join(base, ".cursorrules"))
      File.mkdir_p!(Path.join(base, ".lemon"))
      File.ln_s!(Path.join(home_dir, ".lemon/rules"), Path.join(base, ".lemon/rules"))
      File.ln_s!(Path.join(home_dir, ".lemon/commands"), Path.join(base, ".lemon/commands"))
      rel = Path.relative_to(memory, base)

      write!(
        Path.join(base, "AGENTS.md"),
        "REPO_AGENTS @#{rel} @#{Path.relative_to(home_dir, base)}/USER.md"
      )

      text = rendered(ResourceLoader.instruction_sections(base) ++ Rules.sections(base))
      assert text =~ "REPO_AGENTS @#{rel}"

      for marker <- ~w(HOME_MEMORY_SECRET HOME_USER_SECRET HOME_RULE),
          do: refute(text =~ marker, marker)

      refute "homecmd" in Enum.map(Commands.list(base, home: Path.join(base, "none")), & &1.name)
      assert {:ok, _root} = LemonCore.TrustedRoot.project_root(base)
    end
  end
end
