defmodule LemonChannels.GoalChannelAuthorityTest do
  @moduledoc """
  A chat-set goal runs its judge and continuations under the chat's channel-run
  authority (channel policy, group approval floor, bound workspace), through
  the real automation manager and router submission path.
  """

  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.GoalStore
  alias LemonChannels.GoalStatusMessage
  alias LemonCore.ToolPolicy

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

      runner =
        spawn(fn ->
          monitor = Process.monitor(sink)
          output = if judge?, do: ~s({"action":"continue","reason":"work remains"}), else: "done"

          send(
            sink,
            {:engine_event, ref,
             CodingAgent.Executor.Event.completed(%{engine: "lemon", ok: true, answer: output})}
          )

          receive do
            :cancel -> :ok
            {:DOWN, ^monitor, :process, ^sink, _reason} -> :ok
          end
        end)

      {:ok, ref, %{runner_pid: runner}}
    end
  end

  setup do
    original_runtime = Application.get_env(:lemon_router, :test_executor)
    original_judge = Application.get_env(:lemon_automation, :goal_judge_runner)
    Application.put_env(:lemon_router, :test_executor, Executor)

    Application.put_env(
      :lemon_automation,
      :goal_judge_runner,
      :"Elixir.LemonAutomation.GoalJudge.RouterRunner"
    )

    :persistent_term.put({Executor, :test_pid}, self())
    {:ok, _} = Application.ensure_all_started(:lemon_router)
    {:ok, _} = Application.ensure_all_started(:lemon_automation)

    workspace =
      Path.join(System.tmp_dir!(), "goal-chat-authority-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    {:ok, workspace} = LemonAgent.Workspace.KanbanAuthority.canonical_directory(workspace)
    peer = "-100#{System.unique_integer([:positive])}"
    key = "agent:default:telegram:default:group:#{peer}"

    test_pid = self()

    opts = [
      agent_id: "default",
      workspace: workspace,
      channel_context: %{channel_id: "telegram", peer_kind: :group, peer_id: peer},
      meta: %{transport: "telegram"},
      start_task: &{:ok, spawn(&1)},
      deliver: &send(test_pid, {:goal_reply, &1})
    ]

    on_exit(fn ->
      :"Elixir.LemonAutomation.GoalLoopManager".stop_loop(key)
      GoalStore.clear(key)
      File.rm_rf!(workspace)
      restore(:lemon_router, :test_executor, original_runtime)
      restore(:lemon_automation, :goal_judge_runner, original_judge)
      :persistent_term.erase({Executor, :test_pid})
    end)

    %{key: key, opts: opts, workspace: workspace}
  end

  test "group-chat goal runs keep the group approval floor and bound workspace", %{
    key: key,
    opts: opts,
    workspace: workspace
  } do
    assert GoalStatusMessage.handle(key, "set Fix the failing build", opts) =~ "Goal Set"
    assert GoalStore.get(key).cwd == workspace

    assert GoalStatusMessage.handle(key, "loop once", opts) =~ "Goal Loop Tick Queued"
    assert_receive {:goal_reply, tick}, 5_000
    assert tick =~ "Goal Loop Tick"
    assert tick =~ "Run id:"

    assert_receive {:execution, judge}, 2_000
    assert judge.meta.goal_judge == true
    assert judge.cwd == workspace

    assert_receive {:execution, worker}, 2_000
    assert worker.meta.goal_continuation == true
    assert worker.cwd == workspace

    for tool <- ~w(bash write edit patch) do
      assert ToolPolicy.approval_mode(worker.tool_policy, tool) == :always
    end

    assert GoalStatusMessage.handle(key, "continue", opts) =~ "Goal Continuation Queued"
    assert_receive {:goal_reply, continued_text}, 5_000
    assert continued_text =~ "Goal Continuation Submitted"
    assert_receive {:execution, continued}, 2_000
    assert continued.meta.goal_continuation == true
    assert ToolPolicy.approval_mode(continued.tool_policy, "bash") == :always
  end

  test "a chat without trusted channel context cannot set a goal", %{key: key, opts: opts} do
    text = GoalStatusMessage.handle(key, "set Anything", Keyword.delete(opts, :channel_context))
    refute text =~ "Goal Set"
    assert GoalStore.get(key) == %{}
  end

  test "a chat cannot start a goal whose target is outside its bound workspace", %{
    key: key,
    opts: opts
  } do
    elsewhere =
      Path.join(System.tmp_dir!(), "goal-chat-elsewhere-#{System.unique_integer([:positive])}")

    File.mkdir_p!(elsewhere)
    on_exit(fn -> File.rm_rf!(elsewhere) end)

    assert {:ok, _goal} =
             :"Elixir.LemonAutomation.GoalLoopManager".set_goal(key, "Operator goal elsewhere",
               agent_id: "default",
               cwd: elsewhere,
               authority: LemonAgent.Workspace.GoalAuthority.operator()
             )

    for args <- ["loop once", "loop start", "continue"] do
      text = GoalStatusMessage.handle(key, args, opts)
      refute text =~ "Started"

      if args != "loop start" do
        assert_receive {:goal_reply, delivered}, 5_000
        refute delivered =~ "Submitted"
        refute delivered =~ "Run id:"
      end
    end

    refute_receive {:execution, _command}, 300
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
