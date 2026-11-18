defmodule LemonAutomation.GoalToolTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonAgent.Workspace.GoalStore
  alias LemonAutomation.GoalLoopManager
  alias LemonSkills.Tools.Goal

  defmodule Runtime do
    def available?, do: true
    def run_pid(_run_id), do: nil

    def cancel_by_run_id(run_id, reason) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:cancelled, run_id, reason})
      :ok
    end

    def submit_execution(%LemonCore.ExecutionCommand{} = command) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:execution, command})
      judge? = command.meta[:goal_judge] == true

      if judge? or :persistent_term.get({__MODULE__, :complete}, true) do
        spawn(fn ->
          Process.sleep(25)

          output =
            if judge?,
              do: ~s({"action":"continue","reason":"work remains"}),
              else: "coding result"

          topic = LemonCore.Bus.run_topic(command.run_id)
          meta = %{run_id: command.run_id, session_key: command.session_key}

          LemonCore.Bus.broadcast(
            topic,
            LemonCore.Event.new(:run_started, %{run_id: command.run_id, engine: "lemon"}, meta)
          )

          LemonCore.Bus.broadcast(
            topic,
            LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: output}}, meta)
          )
        end)
      end

      :ok
    end
  end

  setup do
    original_runtime = Application.get_env(:lemon_router, :engine_runtime)
    original_judge = Application.get_env(:lemon_automation, :goal_judge_runner)
    Application.put_env(:lemon_router, :engine_runtime, Runtime)

    Application.put_env(
      :lemon_automation,
      :goal_judge_runner,
      LemonAutomation.GoalJudge.RouterRunner
    )

    :persistent_term.put({Runtime, :test_pid}, self())
    :persistent_term.put({Runtime, :complete}, true)
    {:ok, _} = Application.ensure_all_started(:lemon_router)
    {:ok, _} = Application.ensure_all_started(:lemon_automation)
    key = "agent:default:goal-tool-#{System.unique_integer([:positive])}"
    tool = Goal.tool(System.tmp_dir!(), session_key: key, agent_id: "default")

    on_exit(fn ->
      GoalLoopManager.stop_loop(key)
      GoalStore.clear(key)
      restore(:lemon_router, :engine_runtime, original_runtime)
      restore(:lemon_automation, :goal_judge_runner, original_judge)
      :persistent_term.erase({Runtime, :test_pid})
      :persistent_term.erase({Runtime, :complete})
    end)

    %{tool: tool, key: key}
  end

  test "set and one bounded tick route judge and coding work with durable cwd/results", %{
    tool: tool,
    key: key
  } do
    assert %AgentToolResult{details: %{goal: goal}, trust: :untrusted} =
             tool.execute.(
               "set",
               %{"action" => "set", "objective" => "Implement a change"},
               nil,
               nil
             )

    # The target is the canonical session cwd (symlinks resolved).
    assert {:ok, goal.cwd} ==
             LemonAgent.Workspace.KanbanAuthority.canonical_directory(System.tmp_dir!())

    assert goal.authority["grantedBy"] == "session"

    assert %AgentToolResult{details: %{loop: %{max_ticks: 1}}} =
             tool.execute.("start", %{"action" => "run_once"}, nil, nil)

    assert_receive {:execution, judge}, 2_000
    assert judge.meta.goal_judge == true
    assert judge.cwd == goal.cwd
    refute "goal" in judge.tool_policy.allow
    assert_receive {:execution, worker}, 2_000
    assert worker.meta.goal_continuation == true
    assert worker.cwd == goal.cwd
    assert "goal" in worker.tool_policy.blocked_tools
    refute judge.run_id == worker.run_id

    assert eventually(fn ->
             match?({:ok, %{running: false}}, GoalLoopManager.status(key))
           end)

    assert %AgentToolResult{details: %{goal: completed}} =
             tool.execute.("status", %{"action" => "status"}, nil, nil)

    assert completed.continuation_count == 1
    assert completed.last_run_id == worker.run_id
    assert completed.meta["lastResult"]["output"] == "coding result"
    assert completed.meta["goalLoop"]["status"] == "limit_reached"
    refute_receive {:execution, _}, 100
  end

  test "pause cancels the owned run and resume does not restart automatically", %{
    tool: tool,
    key: key
  } do
    :persistent_term.put({Runtime, :complete}, false)

    assert %AgentToolResult{} =
             tool.execute.("set", %{"action" => "set", "objective" => "Wait for pause"}, nil, nil)

    assert %AgentToolResult{} = tool.execute.("start", %{"action" => "start"}, nil, nil)
    assert_receive {:execution, judge}, 2_000
    assert judge.meta.goal_judge == true
    assert_receive {:execution, worker}, 2_000
    assert worker.meta.goal_continuation == true

    assert %AgentToolResult{details: %{goal: paused, router_abort: :accepted}} =
             tool.execute.("pause", %{"action" => "pause"}, nil, nil)

    assert paused.status == "paused"
    assert paused.meta["goalLoop"]["auto"]["enabled"] == false
    run_id = worker.run_id
    assert_receive {:cancelled, ^run_id, _}, 2_000

    assert {:error, "goal is paused; resume before starting"} =
             tool.execute.("start", %{"action" => "start"}, nil, nil)

    assert %AgentToolResult{details: %{goal: %{status: "active"}}} =
             tool.execute.("resume", %{"action" => "resume"}, nil, nil)

    assert {:ok, %{running: false}} = GoalLoopManager.status(key)
    refute_receive {:execution, _}, 100
  end

  defp eventually(fun, attempts \\ 250)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
