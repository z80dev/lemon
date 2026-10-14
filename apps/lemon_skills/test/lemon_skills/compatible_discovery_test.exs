defmodule LemonSkills.CompatibleDiscoveryTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias LemonSkills.{Config, Registry}
  alias LemonSkills.Tools.ReadSkill

  @moduletag :tmp_dir
  @env_keys ~w(LEMON_AGENT_DIR LEMON_HARNESS_SKILLS_DIR LEMON_OMP_SKILLS_DIR LEMON_CLAUDE_SKILLS_DIR LEMON_CODEX_SKILLS_DIR)
  @app_keys [
    {:lemon_skills, :agent_dir},
    {:coding_agent, :agent_dir},
    {:lemon_skills, :harness_global_skills_dir},
    {:lemon_skills, :omp_global_skills_dir},
    {:lemon_skills, :claude_global_skills_dir},
    {:lemon_skills, :codex_global_skills_dir}
  ]

  setup %{tmp_dir: tmp_dir} do
    previous_env = Enum.map(@env_keys, &{&1, System.get_env(&1)})

    previous_app =
      Enum.map(@app_keys, fn {app, key} -> {app, key, Application.fetch_env(app, key)} end)

    Enum.each(@env_keys, &System.delete_env/1)
    Enum.each(@app_keys, fn {app, key} -> Application.delete_env(app, key) end)

    roots = %{
      lemon: Path.join(tmp_dir, "agent/skill"),
      agents: Path.join(tmp_dir, "agents"),
      omp: Path.join(tmp_dir, "omp"),
      claude: Path.join(tmp_dir, "claude"),
      codex: Path.join(tmp_dir, "codex")
    }

    System.put_env("LEMON_AGENT_DIR", Path.dirname(roots.lemon))
    System.put_env("LEMON_HARNESS_SKILLS_DIR", roots.agents)
    System.put_env("LEMON_OMP_SKILLS_DIR", roots.omp)
    System.put_env("LEMON_CLAUDE_SKILLS_DIR", roots.claude)
    System.put_env("LEMON_CODEX_SKILLS_DIR", roots.codex)
    repo = Path.join(tmp_dir, "repo")
    cwd = Path.join(repo, "packages/app")
    File.mkdir_p!(cwd)
    File.write!(Path.join(repo, ".git"), "gitdir: ../worktree-metadata\n")
    Registry.refresh()

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(previous_app, fn
        {app, key, :error} -> Application.delete_env(app, key)
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
      end)

      Registry.refresh()
    end)

    %{roots: roots, repo: repo, cwd: cwd}
  end

  test "global defaults and explicit overrides preserve isolation", %{roots: roots} do
    assert Config.global_skills_dirs() == [
             roots.lemon,
             roots.agents,
             roots.omp,
             roots.claude,
             roots.codex
           ]

    System.delete_env("LEMON_OMP_SKILLS_DIR")
    System.delete_env("LEMON_CLAUDE_SKILLS_DIR")
    System.delete_env("LEMON_CODEX_SKILLS_DIR")
    assert Config.global_skills_dirs() == [roots.lemon, roots.agents]

    Application.put_env(:lemon_skills, :codex_global_skills_dir, roots.codex)
    assert Config.global_skills_dirs() == [roots.lemon, roots.agents, roots.codex]
    Application.delete_env(:lemon_skills, :codex_global_skills_dir)

    Application.put_env(:lemon_skills, :omp_global_skills_dir, roots.omp)
    assert Config.global_skills_dirs() == [roots.lemon, roots.agents, roots.omp]
    System.put_env("LEMON_OMP_SKILLS_DIR", roots.claude)
    assert Config.global_skills_dirs() == [roots.lemon, roots.agents, roots.claude]

    Enum.each(@env_keys, &System.delete_env/1)
    Enum.each(@app_keys, fn {app, key} -> Application.delete_env(app, key) end)
    home = System.user_home!()

    assert Config.global_skills_dirs() ==
             Enum.map(
               [
                 ".lemon/agent/skill",
                 ".agents/skills",
                 ".omp/agent/skills",
                 ".claude/skills",
                 ".codex/skills"
               ],
               &Path.join(home, &1)
             )

    Application.put_env(:coding_agent, :agent_dir, Path.dirname(roots.lemon))
    refute Path.join(home, ".claude/skills") in Config.global_skills_dirs()
    refute Path.join(home, ".omp/agent/skills") in Config.global_skills_dirs()
    refute Path.join(home, ".codex/skills") in Config.global_skills_dirs()
  end

  test "global collisions use Lemon, harness, OMP, Claude, then Codex", %{roots: roots} do
    ordered = [roots.lemon, roots.agents, roots.omp, roots.claude, roots.codex]
    Enum.each(ordered, &write_skill(&1, "shared", "Shared display name", "body"))

    Enum.each(ordered, fn root ->
      Registry.refresh()
      assert {:ok, entry} = Registry.get("shared")
      assert entry.path == Path.join(root, "shared")
      assert entry.source == :global
      File.rm_rf!(entry.path)
    end)

    Registry.refresh()
    assert :error = Registry.get("shared")
  end

  test "nearest scope wins before provider, stops at worktree boundary", %{
    roots: roots,
    repo: repo,
    cwd: cwd,
    tmp_dir: tmp_dir
  } do
    ordered = [
      Path.join(cwd, ".lemon/skill"),
      Path.join(cwd, ".agents/skills"),
      Path.join(cwd, ".omp/skills"),
      Path.join(cwd, ".claude/skills"),
      Path.join(cwd, ".codex/skills"),
      Path.join(cwd, ".github/skills"),
      Path.join(repo, ".agents/skills"),
      Path.join(repo, ".omp/skills"),
      Path.join(repo, ".claude/skills"),
      Path.join(repo, ".codex/skills"),
      Path.join(repo, ".github/skills")
    ]

    Enum.each(ordered, &write_skill(&1, "shared", "Shared", "project"))
    write_skill(roots.lemon, "shared", "Shared", "global")
    write_skill(Path.join(tmp_dir, ".claude/skills"), "outside", "Outside", "outside")
    write_skill(Path.join(repo, ".lemon/skill"), "ancestor-lemon", "Ancestor", "ignored")
    assert Config.project_skills_dirs(cwd) == ordered

    Enum.each(ordered, fn root ->
      Registry.refresh(cwd: cwd)
      assert {:ok, entry} = Registry.get("shared", cwd: cwd)
      assert entry.path == Path.join(root, "shared")
      assert entry.source == :project
      File.rm_rf!(entry.path)
    end)

    Registry.refresh(cwd: cwd)
    assert {:ok, entry} = Registry.get("shared", cwd: cwd)
    assert entry.source == :global
    assert :error = Registry.get("outside", cwd: cwd)
    assert :error = Registry.get("ancestor-lemon", cwd: cwd)
  end

  test "compatible bundles load on demand, stay untrusted and use directory keys", %{cwd: cwd} do
    root = Path.join(cwd, ".claude/skills")
    path = write_skill(root, "deploy", "Deployment guide", "first body")
    File.mkdir_p!(Path.join(path, "references"))
    File.write!(Path.join(path, "references/details.md"), "deployment reference")
    Registry.refresh(cwd: cwd)
    assert :error = Registry.get("deploy")
    assert :error = Registry.get("Deployment guide", cwd: cwd)

    assert %AgentToolResult{trust: :untrusted, content: [%TextContent{text: text}]} =
             ReadSkill.execute("compat-full", %{"key" => "deploy"}, nil, nil, cwd)

    assert text =~ "first body"

    write_skill(root, "deploy", "Deployment guide", "newer body")
    Registry.refresh(cwd: cwd)

    assert %AgentToolResult{trust: :untrusted, content: [%TextContent{text: updated}]} =
             ReadSkill.execute("compat-new", %{"key" => "deploy"}, nil, nil, cwd)

    assert updated =~ "newer body"
    refute updated =~ "first body"

    assert %AgentToolResult{trust: :untrusted, content: [%TextContent{text: reference}]} =
             ReadSkill.execute(
               "compat-file",
               %{"key" => "deploy", "view" => "file", "path" => "references/details.md"},
               nil,
               nil,
               cwd
             )

    assert reference =~ "deployment reference"
  end

  test "one-level discovery skips invalid bundles and listings are key-sorted", %{cwd: cwd} do
    root = Path.join(cwd, ".omp/skills")
    write_skill(root, "zulu", "Zulu", "body")
    write_skill(root, "alpha", "Alpha", "body")
    write_skill(Path.join(root, "group"), "nested", "Nested", "not discovered")
    invalid = write_skill(root, "invalid", "Invalid", "body")
    File.write!(Path.join(invalid, "SKILL.md"), "---\nname: Invalid\nplatforms: linux\n---\nbody")
    Registry.refresh(cwd: cwd)
    assert Enum.map(Registry.list(cwd: cwd), & &1.key) == ["alpha", "zulu"]
    assert :error = Registry.get("nested", cwd: cwd)
    assert :error = Registry.get("invalid", cwd: cwd)
  end

  defp write_skill(root, key, name, body) do
    path = Path.join(root, key)
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, "SKILL.md"),
      "---\nname: #{name}\ndescription: Compatible skill\n---\n#{body}\n"
    )

    path
  end
end
