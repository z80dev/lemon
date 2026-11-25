defmodule LemonAutomation.GoalAuthorityTest do
  @moduledoc """
  Goal judge and continuation runs execute under the authority recorded by the
  caller that set (and narrowed by the caller that started) the goal, through
  the real router submission path.
  """

  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonAutomation.{GoalAuthority, GoalStore}
  alias LemonAutomation.GoalLoopManager
  alias LemonCore.ToolPolicy
  alias LemonAutomation.Tools.Goal

  defmodule Executor do
    @behaviour CodingAgent.Executor.Behaviour

    def cancel(%{runner_pid: pid}),
      do:
        (
          send(pid, :cancel)
          :ok
        )

    def steer(_ctx, _prompt), do: {:error, :unsupported}
    def redirect(_ctx, _prompt), do: {:error, :unsupported}

    def start_run(%LemonCore.ExecutionCommand{} = command, _opts, sink) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:execution, command})
      judge? = command.meta[:goal_judge] == true
      ref = make_ref()
      hold? = not judge? and :persistent_term.get({__MODULE__, :hold}, false)

      runner =
        spawn(fn ->
          monitor = Process.monitor(sink)

          unless hold? do
            output =
              if judge?, do: ~s({"action":"continue","reason":"work remains"}), else: "done"

            send(
              sink,
              {:engine_event, ref,
               CodingAgent.Executor.Event.completed(%{engine: "lemon", ok: true, answer: output})}
            )
          end

          receive do
            :cancel -> :ok
            {:DOWN, ^monitor, :process, ^sink, _reason} -> :ok
          end
        end)

      {:ok, ref, %{runner_pid: runner}}
    end
  end

  # The setting session may not run bash or grep and must approve every write.
  @restricted %{blocked_tools: ["bash", "grep"], approvals: %{"write" => :always}}

  setup do
    original_runtime = Application.get_env(:lemon_router, :test_executor)
    original_judge = Application.get_env(:lemon_automation, :goal_judge_runner)
    Application.put_env(:lemon_router, :test_executor, Executor)

    Application.put_env(
      :lemon_automation,
      :goal_judge_runner,
      LemonAutomation.GoalJudge.RouterRunner
    )

    :persistent_term.put({Executor, :test_pid}, self())
    {:ok, _} = Application.ensure_all_started(:lemon_router)
    {:ok, _} = Application.ensure_all_started(:lemon_automation)

    base = Path.join(System.tmp_dir!(), "goal-authority-#{System.unique_integer([:positive])}")
    root = Path.join(base, "project")
    outside = Path.join(base, "outside")
    File.mkdir_p!(Path.join(root, "work"))
    File.mkdir_p!(outside)
    {:ok, root} = LemonAutomation.KanbanAuthority.canonical_directory(root)
    {:ok, outside} = LemonAutomation.KanbanAuthority.canonical_directory(outside)

    key = "agent:default:goal-authority-#{System.unique_integer([:positive])}"

    tool =
      Goal.tool(root, session_key: key, agent_id: "default", tool_policy: @restricted)

    on_exit(fn ->
      GoalLoopManager.stop_loop(key)
      GoalStore.clear(key)
      File.rm_rf!(base)
      restore(:lemon_router, :test_executor, original_runtime)
      restore(:lemon_automation, :goal_judge_runner, original_judge)
      :persistent_term.erase({Executor, :test_pid})
      :persistent_term.erase({Executor, :hold})
    end)

    %{tool: tool, key: key, root: root, outside: outside}
  end

  test "judge and continuation runs carry the setting session's tool policy", %{
    tool: tool,
    key: key,
    root: root
  } do
    assert %AgentToolResult{details: %{goal: goal}} =
             tool.execute.("set", %{"action" => "set", "objective" => "Fix it"}, nil, nil)

    assert goal.cwd == root

    assert %AgentToolResult{} = tool.execute.("start", %{"action" => "run_once"}, nil, nil)

    assert_receive {:execution, judge}, 2_000
    assert judge.meta.goal_judge == true
    refute ToolPolicy.allowed?(judge.tool_policy, "grep")
    assert ToolPolicy.allowed?(judge.tool_policy, "read")

    assert_receive {:execution, worker}, 2_000
    assert worker.meta.goal_continuation == true
    assert worker.cwd == root
    refute ToolPolicy.allowed?(worker.tool_policy, "bash")
    refute ToolPolicy.allowed?(worker.tool_policy, "goal")
    assert ToolPolicy.approval_mode(worker.tool_policy, "write") == :always

    assert eventually(fn -> match?({:ok, %{running: false}}, GoalLoopManager.status(key)) end)
  end

  test "continuations cannot launder authority through cron or other delegation tools", %{
    tool: tool,
    key: key,
    root: root
  } do
    # Even a setter whose own policy allows cron, task and agent delegation:
    # goal runs never get a tool that starts work without the goal authority.
    permissive =
      Goal.tool(root, session_key: key, agent_id: "default", tool_policy: %{blocked_tools: []})

    assert %AgentToolResult{} =
             permissive.execute.("set", %{"action" => "set", "objective" => "Go"}, nil, nil)

    assert %AgentToolResult{} = tool.execute.("start", %{"action" => "run_once"}, nil, nil)
    assert_receive {:execution, judge}, 2_000
    assert_receive {:execution, worker}, 2_000

    for name <- ~w(cron kanban goal task agent agent_message peer nodes) do
      refute ToolPolicy.allowed?(worker.tool_policy, name), name
      refute ToolPolicy.allowed?(judge.tool_policy, name), name
    end

    # The tool set a continuation session actually builds has no cron tool
    # (contributed by this app) and none of the denied tools.
    names =
      CodingAgent.ToolRegistry.list_tool_names(worker.cwd,
        tool_policy: worker.tool_policy,
        include_extensions: false,
        include_mcp: false
      )

    assert "read" in names
    refute "cron" in names
    refute "task" in names
    refute "bash" in names

    assert eventually(fn -> match?({:ok, %{running: false}}, GoalLoopManager.status(key)) end)
  end

  test "judge and continuation runs are bound to the checked directory identity", %{
    tool: tool,
    key: key,
    root: root,
    outside: outside
  } do
    :persistent_term.put({Executor, :hold}, true)

    assert %AgentToolResult{} =
             tool.execute.(
               "set",
               %{"action" => "set", "objective" => "Bind", "cwd" => "work"},
               nil,
               nil
             )

    work = Path.join(root, "work")
    assert %AgentToolResult{} = tool.execute.("start", %{"action" => "run_once"}, nil, nil)
    assert_receive {:execution, judge}, 2_000
    assert_receive {:execution, worker}, 2_000

    for command <- [judge, worker] do
      assert command.cwd == work
      assert command.meta.cwd_identity == identity(work)
      assert :ok = CodingAgent.CwdIdentity.verify(command.cwd, command.meta.cwd_identity)
    end

    # The directory is swapped for an outside link after submission, while the
    # continuation is queued: the runner's start and per-tool checks refuse it.
    File.rm_rf!(work)
    File.ln_s!(outside, work)

    assert {:error, :cwd_identity_mismatch} =
             CodingAgent.CwdIdentity.verify(worker.cwd, worker.meta.cwd_identity)
  end

  test "the router refuses goal runs that carry no directory identity", %{key: key, root: root} do
    for origin <- [:goal, :goal_judge] do
      assert {:error, _reason} =
               LemonRouter.submit(%{
                 origin: origin,
                 session_key: key,
                 agent_id: "default",
                 prompt: "unbound",
                 cwd: root,
                 run_id: LemonCore.Id.run_id(),
                 meta: %{goal_continuation: true}
               })
    end

    refute_receive {:execution, _command}, 300
  end

  test "a session cannot start an operator goal whose target is outside its own cwd", %{
    tool: tool,
    key: key,
    outside: outside
  } do
    assert {:ok, _goal} =
             GoalLoopManager.set_goal(key, "Operator goal elsewhere",
               agent_id: "default",
               cwd: outside,
               authority: GoalAuthority.operator()
             )

    assert {:error, message} = tool.execute.("start", %{"action" => "run_once"}, nil, nil)
    assert message =~ "outside this session's working directory"
    assert {:error, _} = tool.execute.("start", %{"action" => "start"}, nil, nil)
    refute_receive {:execution, _command}, 300
    assert GoalStore.get(key).authority["unrestricted"]
  end

  test "a session cannot start a goal bound to another agent", %{key: key, root: root} do
    assert {:ok, _goal} =
             GoalLoopManager.set_goal(key, "Operator goal for ops",
               agent_id: "ops",
               cwd: root,
               authority: GoalAuthority.operator()
             )

    tool = Goal.tool(root, session_key: key, agent_id: "default", tool_policy: @restricted)
    assert {:error, message} = tool.execute.("start", %{"action" => "run_once"}, nil, nil)
    assert message =~ "another agent"
    refute_receive {:execution, _command}, 300
  end

  test "a goal target outside the session working directory is refused", %{
    tool: tool,
    key: key,
    outside: outside
  } do
    assert {:error, _reason} =
             tool.execute.(
               "set",
               %{"action" => "set", "objective" => "Escape", "cwd" => outside},
               nil,
               nil
             )

    assert GoalStore.get(key) == %{}
  end

  test "a restricted starter durably narrows an operator-set goal", %{
    tool: tool,
    key: key,
    root: root
  } do
    # Operator surfaces (control plane goal.set, web) record operator authority.
    assert {:ok, _goal} =
             GoalLoopManager.set_goal(key, "Operator goal",
               agent_id: "default",
               cwd: root,
               authority: GoalAuthority.operator()
             )

    assert %AgentToolResult{} = tool.execute.("start", %{"action" => "run_once"}, nil, nil)
    assert_receive {:execution, %{meta: %{goal_judge: true}}}, 2_000
    assert_receive {:execution, worker}, 2_000
    refute ToolPolicy.allowed?(worker.tool_policy, "bash")
    assert eventually(fn -> match?({:ok, %{running: false}}, GoalLoopManager.status(key)) end)

    # A later operator start (web, auto restart) keeps the narrowed authority.
    assert {:ok, _loop} = GoalLoopManager.start_loop(key, max_ticks: 1)
    assert_receive {:execution, %{meta: %{goal_judge: true}}}, 2_000
    assert_receive {:execution, later}, 2_000
    refute ToolPolicy.allowed?(later.tool_policy, "bash")
    assert eventually(fn -> match?({:ok, %{running: false}}, GoalLoopManager.status(key)) end)
  end

  test "a policy-bound starter cannot join or auto-restart a loop running under broader authority",
       %{key: key, root: root} do
    :persistent_term.put({Executor, :hold}, true)

    assert {:ok, _goal} =
             GoalLoopManager.set_goal(key, "Operator goal",
               cwd: root,
               authority: GoalAuthority.operator()
             )

    assert {:ok, _loop} = GoalLoopManager.start_loop(key, max_ticks: 1)
    assert_receive {:execution, %{meta: %{goal_continuation: true}}}, 2_000

    {:ok, starter} =
      GoalAuthority.new(%{agent_id: "default", session_key: key}, @restricted, root)

    assert {:error, :already_running} =
             GoalLoopManager.start_loop(key, auto: true, starter: starter)

    refute GoalStore.get(key).meta["goalLoop"]["auto"]["enabled"]
    assert GoalStore.get(key).authority["unrestricted"]
  end

  test "auto recovery and explicit starts refuse a goal without recorded authority", %{
    key: key,
    root: root
  } do
    now = System.system_time(:millisecond)

    legacy = %{
      id: "goal_legacy#{System.unique_integer([:positive])}",
      session_key: key,
      agent_id: "default",
      cwd: root,
      objective: "Persisted before goal authority existed",
      status: "active",
      created_at_ms: now,
      updated_at_ms: now,
      continuation_count: 0,
      budget: %{},
      meta: %{"goalLoop" => %{"auto" => %{"enabled" => true}}}
    }

    :ok = LemonCore.Store.put(:goals, key, legacy)

    send(GoalLoopManager, :auto_tick)
    assert {:ok, _status} = GoalLoopManager.status(key)

    assert {:ok, %{^key => %{running: running, control_revision: revision}}} =
             GoalLoopManager.status_many([key])

    assert is_boolean(running) and is_binary(revision)
    refute_receive {:execution, _command}, 300

    assert {:error, _reason} = GoalLoopManager.start_loop(key, max_ticks: 1)
    refute_receive {:execution, _command}, 300
  end

  test "runs re-resolve the goal target and refuse a swapped workspace", %{
    tool: tool,
    root: root,
    outside: outside
  } do
    assert %AgentToolResult{details: %{goal: goal}} =
             tool.execute.(
               "set",
               %{"action" => "set", "objective" => "Stay inside", "cwd" => "work"},
               nil,
               nil
             )

    assert goal.cwd == Path.join(root, "work")

    File.rm_rf!(Path.join(root, "work"))
    File.ln_s!(outside, Path.join(root, "work"))

    _ = tool.execute.("start", %{"action" => "run_once"}, nil, nil)
    refute_receive {:execution, _command}, 500
  end

  defp identity(path) do
    stat = File.stat!(path)
    %{"major" => stat.major_device, "minor" => stat.minor_device, "inode" => stat.inode}
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
