defmodule CodingAgent.SubagentsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Subagents

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    original_home = System.get_env("HOME")
    home_dir = Path.join(tmp_dir, "home")
    File.mkdir_p!(home_dir)
    System.put_env("HOME", home_dir)

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end
    end)

    {:ok, home_dir: home_dir}
  end

  test "filters invalid entries and merges overrides", %{tmp_dir: tmp_dir, home_dir: home_dir} do
    project_dir = Path.join(tmp_dir, "project")
    project_config = Path.join(project_dir, ".lemon")
    File.mkdir_p!(project_config)

    project_agents = [
      %{"id" => "", "prompt" => "ignored"},
      %{"id" => "custom", "prompt" => "   "},
      %{"id" => "custom2", "prompt" => "Do work", "description" => 123},
      %{"id" => "review", "prompt" => "Override review", "description" => "Override"}
    ]

    File.write!(Path.join(project_config, "subagents.json"), Jason.encode!(project_agents))

    agent_dir = CodingAgent.Config.agent_dir()
    global_path = Path.join(agent_dir, "subagents.json")
    if String.starts_with?(agent_dir, home_dir) do
      File.mkdir_p!(agent_dir)
      global_agents = [%{"id" => "global", "prompt" => "Global prompt"}]
      File.write!(global_path, Jason.encode!(global_agents))
    end

    agents = Subagents.list(project_dir)

    assert Subagents.get(project_dir, "custom") == nil
    assert Subagents.get(project_dir, "custom2").prompt == "Do work"
    assert Subagents.get(project_dir, "custom2").description == ""
    assert Subagents.get(project_dir, "review").prompt == "Override review"
    if String.starts_with?(agent_dir, home_dir) do
      assert Subagents.get(project_dir, "global").prompt == "Global prompt"
    end

    ids = Enum.map(agents, & &1.id)
    refute "" in ids
  end
end
