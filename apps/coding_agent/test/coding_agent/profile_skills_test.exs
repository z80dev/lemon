defmodule CodingAgent.ProfileSkillsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{SystemPrompt, Workspace}
  alias CodingAgent.Tools.ReadSkill
  alias LemonCore.ProfileStore

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_home = System.get_env("HOME")
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    home = Path.join(root, "home")
    agent_dir = Path.join(root, "agent")
    File.mkdir_p!(home)
    File.mkdir_p!(agent_dir)
    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", agent_dir)
    Application.put_env(:lemon_core, :paths, home_state_dir: Path.join(root, "state"))
    {:ok, alpha} = ProfileStore.paths("skill-alpha")
    {:ok, beta} = ProfileStore.paths("skill-beta")
    cwd = Path.join(root, "destination-project")
    for scope <- [alpha["workspace"], beta["workspace"], cwd], do: File.mkdir_p!(scope)
    LemonSkills.refresh()

    on_exit(fn ->
      for scope <- [alpha["workspace"], beta["workspace"], cwd] do
        File.rm_rf!(Path.join([scope, ".lemon", "skill"]))
        LemonSkills.refresh(cwd: scope)
      end
      if previous_paths, do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)
      restore_env("HOME", previous_home)
      restore_env("LEMON_AGENT_DIR", previous_agent_dir)
      LemonSkills.refresh()
    end)

    %{alpha: alpha, beta: beta, cwd: cwd}
  end

  test "selected metadata loads at profile scope and full skill body loads only on demand", %{alpha: alpha, cwd: cwd} do
    body = "PRIVATE_SELECTED_BODY_BEGIN\n" <> String.duplicate("Exact selected instruction line.\n", 8_192) <> "PRIVATE_SELECTED_BODY_END\n"
    write_skill(alpha["workspace"], "selected-operating", "Selected Operating", "Selected metadata only", body)
    write_skill(cwd, "project-only", "Project Only", "Unrelated project metadata", "UNRELATED_PROJECT_BODY")
    LemonSkills.refresh(cwd: alpha["workspace"])
    LemonSkills.refresh(cwd: cwd)
    opts = %{agent_id: "skill-alpha", workspace_dir: alpha["workspace"],
      contributed_sections: [], tool_names: ["read_skill"]}
    prompt = SystemPrompt.build(cwd, opts)
    assert prompt =~ "Selected Operating"
    assert prompt =~ "Selected metadata only"
    refute prompt =~ "PRIVATE_SELECTED_BODY_BEGIN"
    refute prompt =~ "Project Only"
    assert Workspace.skill_cwd(cwd, opts) == alpha["workspace"]
    tool = ReadSkill.tool(cwd, agent_id: "skill-alpha", workspace_dir: alpha["workspace"])
    result = tool.execute.("selected-read", %{"key" => "selected-operating"}, nil, nil)
    assert text(result) =~ body
    assert result.details.path == Path.join(alpha["skills"], "selected-operating")

    # Rebuilding a subsequent prompt remains metadata-only and preserves the
    # authoritative destination skill root rather than the execution cwd.
    refreshed = SystemPrompt.build(cwd, opts)
    assert refreshed =~ "Selected Operating"
    refute refreshed =~ "PRIVATE_SELECTED_BODY_BEGIN"
  end

  test "profile skill scopes remain isolated and generic project lookup stays unchanged", %{alpha: alpha, beta: beta, cwd: cwd} do
    write_skill(alpha["workspace"], "shared-key", "Alpha Skill", "Alpha metadata", "ALPHA_BODY")
    write_skill(beta["workspace"], "shared-key", "Beta Skill", "Beta metadata", "BETA_BODY")
    write_skill(cwd, "shared-key", "Project Skill", "Project metadata", "PROJECT_BODY")
    for scope <- [alpha["workspace"], beta["workspace"], cwd], do: LemonSkills.refresh(cwd: scope)
    for {id, profile, own, other} <- [{"skill-alpha", alpha, "ALPHA_BODY", "BETA_BODY"}, {"skill-beta", beta, "BETA_BODY", "ALPHA_BODY"}] do
      tool = ReadSkill.tool(cwd, agent_id: id, workspace_dir: profile["workspace"])
      result = tool.execute.("isolated-read", %{"key" => "shared-key"}, nil, nil)
      assert text(result) =~ own
      refute text(result) =~ other
      refute text(result) =~ "PROJECT_BODY"
    end
    generic = ReadSkill.tool(cwd, agent_id: "ordinary-agent", workspace_dir: alpha["workspace"])
    assert text(generic.execute.("generic-read", %{"key" => "shared-key"}, nil, nil)) =~ "PROJECT_BODY"
    assert Workspace.skill_cwd(cwd, %{agent_id: "ordinary-agent", workspace_dir: alpha["workspace"]}) == cwd
    prompt = SystemPrompt.build(cwd, %{agent_id: "ordinary-agent", workspace_dir: alpha["workspace"], contributed_sections: [], tool_names: ["read_skill"]})
    assert prompt =~ "Project Skill"
    refute prompt =~ "Alpha Skill"
  end

  defp write_skill(scope, key, name, description, body) do
    directory = Path.join([scope, ".lemon", "skill", key])
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "SKILL.md"), "---\nname: #{name}\ndescription: #{description}\n---\n\n" <> body)
  end

  defp text(result), do: Enum.map_join(result.content, "\n", & &1.text)
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
