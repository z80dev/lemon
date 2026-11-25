defmodule LemonAutomation.ChatCommands.GoalTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.ChatCommands.Goal
  alias LemonAutomation.GoalStore

  defmodule HangingLoop do
    @moduledoc false

    # A judge that hangs until the manager call deadline exits the caller.
    def run_once(session_key, opts) do
      send(:persistent_term.get(:goal_status_message_test_pid), {:hang, session_key, self()})

      receive do
        :release -> exit({:timeout, {GenServer, :call, [__MODULE__, {:run_once, opts}]}})
      end
    end
  end

  defmodule FakeLoop do
    @moduledoc false

    def run_once(session_key, opts) do
      send(:persistent_term.get(:goal_status_message_test_pid), {:loop_once, session_key, opts})

      {:ok,
       %{
         run_id: "run_loop_once",
         goal: %{
           id: "goal_channel",
           status: "active",
           objective: "private objective",
           continuation_count: 2
         },
         verdict: %{action: :continue, reason: "still open", source: "test"}
       }}
    end

    def start_loop(session_key, opts) do
      send(:persistent_term.get(:goal_status_message_test_pid), {:loop_start, session_key, opts})
      {:ok, %{session_key: session_key, status: "running", max_ticks: opts[:max_ticks] || 3}}
    end

    def status(session_key) do
      send(:persistent_term.get(:goal_status_message_test_pid), {:loop_status, session_key})

      {:ok,
       %{
         running: true,
         loop: %{session_key: session_key, status: "running", max_ticks: 3},
         goal: %{status: "active", continuation_count: 2}
       }}
    end

    def stop_loop(session_key) do
      send(:persistent_term.get(:goal_status_message_test_pid), {:loop_stop, session_key})

      {:ok,
       %{
         loop: %{session_key: session_key, status: "stopped", max_ticks: 3},
         goal: %{status: "paused", continuation_count: 2}
       }}
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_automation)
    :persistent_term.put(:goal_status_message_test_pid, self())
    on_exit(fn -> :persistent_term.erase(:goal_status_message_test_pid) end)
    :ok
  end

  test "renders redacted goal status text" do
    session_key = session_key()
    private_objective = "ship private hermes parity details"

    on_exit(fn -> GoalStore.clear(session_key) end)

    set_text =
      Goal.handle(session_key, "set #{private_objective}", chat_opts())

    status_text = Goal.handle(session_key, "status")

    assert set_text =~ "Goal Set"
    assert set_text =~ "Objective bytes:"
    refute set_text =~ private_objective

    assert status_text =~ "Goal Status"
    assert status_text =~ "State: active"
    assert status_text =~ "Objective bytes:"
    refute status_text =~ private_objective
    refute status_text =~ session_key
  end

  test "sets and renders max continuation budget" do
    session_key = session_key()
    on_exit(fn -> GoalStore.clear(session_key) end)

    set_text =
      Goal.handle(session_key, "set --max-continuations 3 ship it", chat_opts())

    status_text = Goal.handle(session_key, "status")

    assert set_text =~ "Goal Set"
    assert set_text =~ "Max continuations: 3"
    assert status_text =~ "Max continuations: 3"
  end

  test "cannot replace a goal while its run outcome is unresolved" do
    key = session_key()
    assert Goal.handle(key, "set Original", chat_opts()) =~ "Goal Set"
    run_id = "run_goal_channel_#{System.unique_integer([:positive])}"

    {:ok, _} =
      GoalStore.record_loop_status(key, :reconciling, run_id: run_id, run_kind: :continuation)

    on_exit(fn ->
      LemonCore.RunStore.finalize(run_id, %{completed: %{ok: false, error: :aborted}})
      LemonAutomation.GoalLoopManager.status(key)
      GoalStore.clear(key)
    end)

    text = Goal.handle(key, "set Replacement", chat_opts())
    assert text =~ "active or unresolved work"
    assert GoalStore.get(key).objective == "Original"
  end

  test "clears goal state" do
    session_key = session_key()
    on_exit(fn -> GoalStore.clear(session_key) end)

    assert Goal.handle(session_key, "set ship it", chat_opts()) =~ "Goal Set"
    assert Goal.handle(session_key, "clear") == "Goal cleared."
    assert Goal.handle(session_key, "") =~ "State: none"
  end

  test "pauses and resumes goal state" do
    session_key = session_key()
    private_objective = "pause private goal #{System.unique_integer([:positive])}"

    on_exit(fn -> GoalStore.clear(session_key) end)

    assert Goal.handle(session_key, "set #{private_objective}", chat_opts()) =~
             "Goal Set"

    paused_text = Goal.handle(session_key, "pause")
    assert paused_text =~ "Goal Paused"
    assert paused_text =~ "Status: paused"
    refute paused_text =~ private_objective

    resumed_text = Goal.handle(session_key, "resume")
    assert resumed_text =~ "Goal Resumed"
    assert resumed_text =~ "Status: active"
    refute resumed_text =~ private_objective
  end

  test "pause and resume report missing goal" do
    session_key = session_key()

    assert Goal.handle(session_key, "pause") == "No goal is set for this session."
    assert Goal.handle(session_key, "resume") == "No goal is set for this session."
  end

  test "continue submits one continuation off the caller and delivers the run id" do
    session_key = session_key()

    text =
      Goal.handle(
        session_key,
        "continue --max-continuations 4 --model worker-model",
        [loop_module: FakeLoop] ++ chat_opts()
      )

    assert text =~ "Goal Continuation Queued"

    assert_receive {:loop_once, ^session_key,
                    [
                      {:verdict, :continue},
                      {:starter, %{"grantedBy" => "channel", "root" => _}},
                      {:max_continuations, 4},
                      {:model, "worker-model"}
                    ]}

    assert_receive {:goal_reply, delivered, worker}
    refute worker == self()
    assert delivered =~ "Goal Continuation Submitted"
    assert delivered =~ "Run id: run_loop_once"
    assert delivered =~ "Objective bytes: 17"
    refute delivered =~ session_key
    refute delivered =~ "private objective"
  end

  test "a hung judge never blocks the caller and reports an unknown outcome" do
    session_key = session_key()
    started = System.monotonic_time(:millisecond)

    for args <- ["loop once", "continue"] do
      assert Goal.handle(
               session_key,
               args,
               [loop_module: HangingLoop] ++ chat_opts()
             ) =~
               "Queued"
    end

    assert System.monotonic_time(:millisecond) - started < 1_000

    for _ <- 1..2 do
      assert_receive {:hang, ^session_key, worker}
      send(worker, :release)
      assert_receive {:goal_reply, text, ^worker}
      assert text =~ "outcome unknown"
      assert text =~ "/goal loop status"
    end
  end

  test "goal work without a background runner is refused, not run inline" do
    text =
      Goal.handle(
        session_key(),
        "loop once",
        [loop_module: FakeLoop] ++ Keyword.drop(chat_opts(), [:start_task])
      )

    assert text =~ "Goal work unavailable"
    refute_received {:loop_once, _, _}
  end

  test "runs goal loop controls through configured loop module" do
    session_key = session_key()

    once_text =
      Goal.handle(
        session_key,
        "loop once --judge-model judge-model --judge-failure-policy continueOnce",
        [loop_module: FakeLoop] ++ chat_opts()
      )

    assert once_text =~ "Goal Loop Tick Queued"

    assert_receive {:loop_once, ^session_key,
                    [
                      {:starter, %{"grantedBy" => "channel", "root" => _}},
                      {:judge_model, "judge-model"},
                      {:judge_failure_policy, :continue_once}
                    ]}

    assert_receive {:goal_reply, once_text, _worker}
    assert once_text =~ "Goal Loop Tick"
    assert once_text =~ "Run id: run_loop_once"
    assert once_text =~ "Verdict: continue"
    assert once_text =~ "Reason: still open"

    start_text =
      Goal.handle(
        session_key,
        "loop start --auto --max-ticks 5 --interval-ms 20",
        [loop_module: FakeLoop] ++ chat_opts()
      )

    assert_receive {:loop_start, ^session_key,
                    [
                      {:starter, %{"grantedBy" => "channel", "root" => _}},
                      {:auto, true},
                      {:max_ticks, 5},
                      {:interval_ms, 20}
                    ]}

    assert start_text =~ "Goal Loop Started"
    assert start_text =~ "Loop status: running"

    status_text = Goal.handle(session_key, "loop status", loop_module: FakeLoop)
    assert_receive {:loop_status, ^session_key}
    assert status_text =~ "Goal Loop Status"
    assert status_text =~ "Running: true"

    stop_text = Goal.handle(session_key, "loop stop", loop_module: FakeLoop)
    assert_receive {:loop_stop, ^session_key}
    assert stop_text =~ "Goal Loop Stopped"
  end

  test "goal work is refused without trusted channel context" do
    session_key = session_key()

    for args <- ["continue", "loop once", "loop start"] do
      assert Goal.handle(session_key, args,
               agent_id: "agent-1",
               start_task: &start_task/1,
               deliver: &deliver/1,
               loop_module: FakeLoop
             ) =~ "tool policy is unavailable"
    end

    refute_received {:goal_reply, _, _}
    refute_received {:loop_once, _, _}
    refute_received {:loop_start, _, _}
  end

  defp session_key do
    "goal-status-test:#{System.unique_integer([:positive])}"
  end

  defp chat_opts do
    [
      agent_id: "agent-1",
      workspace: System.tmp_dir!(),
      channel_context: %{channel_id: "telegram", peer_kind: :dm, peer_id: "42"},
      start_task: &start_task/1,
      deliver: &deliver/1
    ]
  end

  defp start_task(fun), do: {:ok, spawn(fun)}

  defp deliver(text),
    do: send(:persistent_term.get(:goal_status_message_test_pid), {:goal_reply, text, self()})
end
