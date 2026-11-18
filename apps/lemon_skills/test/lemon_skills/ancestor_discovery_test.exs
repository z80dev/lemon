defmodule LemonSkills.AncestorDiscoveryTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Config
  alias LemonSkills.TestGitRepo

  @moduletag :tmp_dir

  test "collect_ancestor_agents_skill_dirs/1 walks up to git root", %{tmp_dir: tmp_dir} do
    repo_root = TestGitRepo.init!(Path.join(tmp_dir, "repo"))
    nested = Path.join([repo_root, "packages", "feature"])
    File.mkdir_p!(nested)

    dirs = Config.collect_ancestor_agents_skill_dirs(nested)

    assert dirs == [
             Path.join([nested, ".agents", "skills"]),
             Path.join([repo_root, "packages", ".agents", "skills"]),
             Path.join([repo_root, ".agents", "skills"])
           ]
  end

  test "project_skills_dirs/1 precedence is project then ancestors", %{tmp_dir: tmp_dir} do
    repo_root = TestGitRepo.init!(Path.join(tmp_dir, "repo"))
    nested = Path.join([repo_root, "packages", "feature"])
    File.mkdir_p!(nested)

    project_dir = Path.join([nested, ".lemon", "skill"])
    cwd_agents = Path.join([nested, ".agents", "skills"])
    parent_agents = Path.join([repo_root, "packages", ".agents", "skills"])

    File.mkdir_p!(project_dir)
    File.mkdir_p!(cwd_agents)
    File.mkdir_p!(parent_agents)

    assert Config.project_skills_dirs(nested) == [project_dir, cwd_agents, parent_agents]
  end

  test "a profile workspace inside a git repo anchors skills at the workspace", %{
    tmp_dir: tmp_dir
  } do
    repo_root = TestGitRepo.init!(Path.join(tmp_dir, "repo"))
    state = Path.join(repo_root, "state")
    previous = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, home_state_dir: state)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    workspace = LemonCore.Paths.home_path(["profiles", "p", "workspace"])
    File.mkdir_p!(Path.join([workspace, ".lemon", "skill"]))
    File.mkdir_p!(Path.join([repo_root, ".agents", "skills"]))
    src = Path.join(repo_root, "src")
    File.mkdir_p!(src)
    {:ok, real_workspace} = LemonCore.TrustedRoot.realpath(workspace)

    assert LemonCore.TrustedRoot.skill_root(workspace) == real_workspace
    # The workspace's own skills load; nothing above the home is searched.
    assert Config.project_skills_dirs(workspace) == [
             Path.join([real_workspace, ".lemon", "skill"])
           ]

    assert Config.collect_ancestor_agents_skill_dirs(workspace) == [
             Path.join([real_workspace, ".agents", "skills"])
           ]

    # Outside any assistant home the git root still anchors discovery.
    assert LemonCore.TrustedRoot.skill_root(src) == LemonCore.TrustedRoot.resolve(repo_root)
  end
end
