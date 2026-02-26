defmodule LemonRouter.AgentProfilesTest do
  use ExUnit.Case, async: false

  alias LemonRouter.AgentProfiles

  setup do
    original_home = System.get_env("HOME")
    original_cwd = Application.get_env(:lemon_router, :agent_profiles_cwd)
    original_env_cwd = System.get_env("LEMON_AGENT_PROFILES_CWD")

    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "lemon_agent_profiles_#{System.unique_integer([:positive, :monotonic])}"
      )

    home = Path.join(tmp_root, "home")
    project = Path.join(tmp_root, "project")

    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(Path.join(project, ".lemon"))

    on_exit(fn ->
      restore_env("HOME", original_home)
      restore_env("LEMON_AGENT_PROFILES_CWD", original_env_cwd)

      if is_nil(original_cwd) do
        Application.delete_env(:lemon_router, :agent_profiles_cwd)
      else
        Application.put_env(:lemon_router, :agent_profiles_cwd, original_cwd)
      end

      AgentProfiles.reload()
      Process.sleep(25)
      File.rm_rf!(tmp_root)
    end)

    %{home: home, project: project}
  end

  test "loads merged global+project agent profiles using configured cwd", %{
    home: home,
    project: project
  } do
    File.write!(Path.join([home, ".lemon", "config.toml"]), """
    [agents.global_only]
    name = "Global Agent"
    default_engine = "lemon"
    model = "global-model"

    [agents.shared]
    name = "Shared Global"
    default_engine = "lemon"
    model = "shared-global-model"
    """)

    File.write!(Path.join([project, ".lemon", "config.toml"]), """
    [agents.project_only]
    name = "Project Agent"
    default_engine = "lemon"
    model = "project-model"

    [agents.shared]
    name = "Shared Project"
    default_engine = "lemon"
    model = "shared-project-model"
    """)

    System.put_env("HOME", home)
    Application.put_env(:lemon_router, :agent_profiles_cwd, project)

    AgentProfiles.reload()
    Process.sleep(25)

    assert AgentProfiles.exists?("global_only")
    assert AgentProfiles.exists?("project_only")
    assert AgentProfiles.exists?("shared")

    assert AgentProfiles.get("global_only").model == "global-model"
    assert AgentProfiles.get("project_only").model == "project-model"
    assert AgentProfiles.get("shared").model == "shared-project-model"
    assert AgentProfiles.get("shared").name == "Shared Project"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
