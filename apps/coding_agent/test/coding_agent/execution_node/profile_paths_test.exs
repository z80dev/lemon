defmodule CodingAgent.ExecutionNode.ProfilePathsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.ProfilePaths

  @tag :tmp_dir
  test "owning paths reflect actual destination state without creating storage", %{tmp_dir: root} do
    previous = Application.get_env(:lemon_core, :paths)
    state = Path.join(root, "custom-destination-state")
    Application.put_env(:lemon_core, :paths, home_state_dir: state)
    on_exit(fn ->
      if previous, do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)
    workspace = Path.join([state, "profiles", "selected", "workspace"])
    skills = Path.join([workspace, ".lemon", "skill"])
    assert {:ok, %{"profileId" => "selected", "workspacePath" => ^workspace, "skillsPath" => ^skills}} = ProfilePaths.get(%{"profileId" => "selected"})
    refute File.exists?(state)
    for invalid <- [%{"profileId" => "../escape"}, %{"profileId" => "selected", "workspacePath" => root}, %{"profileId" => false}, %{}, nil] do
      assert {:error, :invalid_profile_request} = ProfilePaths.get(invalid)
    end
    refute File.exists?(state)
  end
end
