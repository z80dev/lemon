defmodule LemonSkills.Tools.GoalTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Tools.Goal

  test "schema exposes bounded session-scoped lifecycle operations" do
    tool = Goal.tool(System.tmp_dir!(), session_key: "agent:default:goal-test")
    assert tool.name == "goal"

    assert tool.parameters["properties"]["action"]["enum"] ==
             ~w(set status start stop pause resume run_once)

    assert tool.parameters["properties"]["max_ticks"]["maximum"] == 20
    refute Map.has_key?(tool.parameters["properties"], "session_key")
  end

  test "missing session context does not silently target another session" do
    tool = Goal.tool(System.tmp_dir!())

    assert {:error, "missing session_key in tool context"} =
             tool.execute.("call", %{"action" => "status"}, nil, nil)
  end

  test "set requires an objective and existing target directory before calling runtime" do
    tool =
      Goal.tool(System.tmp_dir!(), session_key: "agent:default:goal-test", agent_id: "default")

    assert {:error, "missing objective"} =
             tool.execute.("call", %{"action" => "set"}, nil, nil)

    assert {:error, "cwd must name an existing directory within the session working directory"} =
             tool.execute.(
               "call",
               %{
                 "action" => "set",
                 "objective" => "Work",
                 "cwd" =>
                   Path.join(
                     System.tmp_dir!(),
                     "missing-goal-#{System.unique_integer([:positive])}"
                   )
               },
               nil,
               nil
             )
  end

  test "set requires the trusted session identity and a target inside the session cwd" do
    tool = Goal.tool(System.tmp_dir!(), session_key: "agent:default:goal-test")

    assert {:error, "goal requires a trusted session identity"} =
             tool.execute.("call", %{"action" => "set", "objective" => "Work"}, nil, nil)

    tool =
      Goal.tool(System.tmp_dir!(), session_key: "agent:default:goal-test", agent_id: "default")

    assert {:error, "cwd must name an existing directory within the session working directory"} =
             tool.execute.(
               "call",
               %{"action" => "set", "objective" => "Work", "cwd" => "/"},
               nil,
               nil
             )
  end

  test "goal supervision destination is normalized and invalid targets never create a goal" do
    session = "agent:default:main:sub:goal_supervision_#{System.unique_integer([:positive])}"
    tool = Goal.tool(System.tmp_dir!(), session_key: session, agent_id: "default")

    assert {:error, _} =
             tool.execute.(
               "call",
               %{"action" => "set", "objective" => "Work", "deliver_to" => "wrong"},
               nil,
               nil
             )

    assert %{} == LemonAgent.Workspace.GoalStore.get(session)

    assert %LemonAgent.Types.AgentToolResult{details: %{goal: goal}} =
             tool.execute.(
               "call",
               %{"action" => "set", "objective" => "Work", "deliver_to" => " NONE "},
               nil,
               nil
             )

    assert goal.meta["deliverTo"] == "none"
    assert goal.authority["grantedBy"] == "session"
    assert goal.authority["principal"] == %{"agentId" => "default", "sessionKey" => session}
    on_exit(fn -> LemonAgent.Workspace.GoalStore.clear(session) end)
  end

  test "start rejects unbounded tick counts before dispatch" do
    tool = Goal.tool(System.tmp_dir!(), session_key: "agent:default:goal-test")

    for ticks <- [0, 21, "3", nil] do
      assert {:error, "max_ticks must be 1..20"} =
               tool.execute.("call", %{"action" => "start", "max_ticks" => ticks}, nil, nil)
    end
  end
end
