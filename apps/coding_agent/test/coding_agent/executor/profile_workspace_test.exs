defmodule CodingAgent.Executor.ProfileWorkspaceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Executor.SessionRunner

  setup do
    previous = Application.get_env(:lemon_core, :paths)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:lemon_core, :paths)
      else
        Application.put_env(:lemon_core, :paths, previous)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "derives the isolated workspace only from a validated profile id", %{tmp_dir: root} do
    state = Path.join(root, "state")
    Application.put_env(:lemon_core, :paths, home_state_dir: state)

    assert SessionRunner.profile_workspace(%{profile_id: "alpha"}) ==
             Path.join([state, "profiles", "alpha", "workspace"])

    assert SessionRunner.profile_workspace(%{"profile_id" => "../escape"}) ==
             CodingAgent.Config.workspace_dir()

    assert SessionRunner.profile_workspace(%{}) == CodingAgent.Config.workspace_dir()
  end
end
