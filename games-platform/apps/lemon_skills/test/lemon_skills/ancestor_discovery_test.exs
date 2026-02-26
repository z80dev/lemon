defmodule LemonSkills.AncestorDiscoveryTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Config

  @moduletag :tmp_dir

  test "find_git_repo_root/1 finds nearest git root", %{tmp_dir: tmp_dir} do
    repo_root = Path.join(tmp_dir, "repo")
    nested = Path.join([repo_root, "a", "b", "c"])

    File.mkdir_p!(nested)
    File.mkdir_p!(Path.join(repo_root, ".git"))

    assert Config.find_git_repo_root(nested) == repo_root
  end

  test "find_git_repo_root/1 returns nil when not in git repo" do
    cwd =
      Path.join([System.tmp_dir!(), "lemon_skills_no_git_#{System.unique_integer([:positive])}"])

    File.mkdir_p!(cwd)

    assert Config.find_git_repo_root(cwd) == nil

    File.rm_rf(cwd)
  end

  test "collect_ancestor_agents_skill_dirs/1 walks up to git root", %{tmp_dir: tmp_dir} do
    repo_root = Path.join(tmp_dir, "repo")
    nested = Path.join([repo_root, "packages", "feature"])

    File.mkdir_p!(nested)
    File.mkdir_p!(Path.join(repo_root, ".git"))

    dirs = Config.collect_ancestor_agents_skill_dirs(nested)

    assert dirs == [
             Path.join([nested, ".agents", "skills"]),
             Path.join([repo_root, "packages", ".agents", "skills"]),
             Path.join([repo_root, ".agents", "skills"])
           ]
  end

  test "project_skills_dirs/1 precedence is project then ancestors", %{tmp_dir: tmp_dir} do
    repo_root = Path.join(tmp_dir, "repo")
    nested = Path.join([repo_root, "packages", "feature"])

    File.mkdir_p!(nested)
    File.mkdir_p!(Path.join(repo_root, ".git"))

    project_dir = Path.join([nested, ".lemon", "skill"])
    cwd_agents = Path.join([nested, ".agents", "skills"])
    parent_agents = Path.join([repo_root, "packages", ".agents", "skills"])

    File.mkdir_p!(project_dir)
    File.mkdir_p!(cwd_agents)
    File.mkdir_p!(parent_agents)

    assert Config.project_skills_dirs(nested) == [project_dir, cwd_agents, parent_agents]
  end
end
