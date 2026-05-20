defmodule LemonChannels.GoalStatusMessageTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.GoalStatusMessage
  alias LemonCore.GoalStore

  defmodule FakeContinuation do
    @moduledoc false

    def continue_once(session_key, opts) do
      send(Process.get(:goal_status_message_test_pid), {:continue_once, session_key, opts})

      {:ok,
       %{
         run_id: "run_channel_continue",
         goal: %{
           id: "goal_channel",
           status: "active",
           objective: "private objective",
           continuation_count: 1
         }
       }}
    end
  end

  defmodule FakeLoop do
    @moduledoc false

    def run_once(session_key, opts) do
      send(Process.get(:goal_status_message_test_pid), {:loop_once, session_key, opts})

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
      send(Process.get(:goal_status_message_test_pid), {:loop_start, session_key, opts})
      {:ok, %{session_key: session_key, status: "running", max_ticks: opts[:max_ticks] || 3}}
    end

    def status(session_key) do
      send(Process.get(:goal_status_message_test_pid), {:loop_status, session_key})

      {:ok,
       %{
         running: true,
         loop: %{session_key: session_key, status: "running", max_ticks: 3},
         goal: %{status: "active", continuation_count: 2}
       }}
    end

    def stop_loop(session_key) do
      send(Process.get(:goal_status_message_test_pid), {:loop_stop, session_key})

      {:ok,
       %{
         loop: %{session_key: session_key, status: "stopped", max_ticks: 3},
         goal: %{status: "paused", continuation_count: 2}
       }}
    end
  end

  setup do
    Process.put(:goal_status_message_test_pid, self())
    :ok
  end

  test "renders redacted goal status text" do
    session_key = session_key()
    private_objective = "ship private hermes parity details"

    on_exit(fn -> GoalStore.clear(session_key) end)

    set_text =
      GoalStatusMessage.handle(session_key, "set #{private_objective}", agent_id: "agent-1")

    status_text = GoalStatusMessage.handle(session_key, "status")

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

    set_text = GoalStatusMessage.handle(session_key, "set --max-continuations 3 ship it")
    status_text = GoalStatusMessage.handle(session_key, "status")

    assert set_text =~ "Goal Set"
    assert set_text =~ "Max continuations: 3"
    assert status_text =~ "Max continuations: 3"
  end

  test "clears goal state" do
    session_key = session_key()
    on_exit(fn -> GoalStore.clear(session_key) end)

    assert GoalStatusMessage.handle(session_key, "set ship it") =~ "Goal Set"
    assert GoalStatusMessage.handle(session_key, "clear") == "Goal cleared."
    assert GoalStatusMessage.handle(session_key, "") =~ "State: none"
  end

  test "pauses and resumes goal state" do
    session_key = session_key()
    private_objective = "pause private goal #{System.unique_integer([:positive])}"

    on_exit(fn -> GoalStore.clear(session_key) end)

    assert GoalStatusMessage.handle(session_key, "set #{private_objective}") =~ "Goal Set"

    paused_text = GoalStatusMessage.handle(session_key, "pause")
    assert paused_text =~ "Goal Paused"
    assert paused_text =~ "Status: paused"
    refute paused_text =~ private_objective

    resumed_text = GoalStatusMessage.handle(session_key, "resume")
    assert resumed_text =~ "Goal Resumed"
    assert resumed_text =~ "Status: active"
    refute resumed_text =~ private_objective
  end

  test "pause and resume report missing goal" do
    session_key = session_key()

    assert GoalStatusMessage.handle(session_key, "pause") == "No goal is set for this session."
    assert GoalStatusMessage.handle(session_key, "resume") == "No goal is set for this session."
  end

  test "continues a goal through configured continuation module" do
    session_key = session_key()

    text =
      GoalStatusMessage.handle(session_key, "continue --max-continuations 4 --model worker-model",
        continuation_module: FakeContinuation
      )

    assert_receive {:continue_once, ^session_key, [max_continuations: 4, model: "worker-model"]}

    assert text =~ "Goal Continuation Submitted"
    assert text =~ "Run id: run_channel_continue"
    assert text =~ "Objective bytes: 17"
    refute text =~ session_key
    refute text =~ "private objective"
  end

  test "runs goal loop controls through configured loop module" do
    session_key = session_key()

    once_text =
      GoalStatusMessage.handle(
        session_key,
        "loop once --judge-model judge-model --judge-failure-policy continueOnce",
        loop_module: FakeLoop
      )

    assert_receive {:loop_once, ^session_key,
                    [judge_model: "judge-model", judge_failure_policy: :continue_once]}

    assert once_text =~ "Goal Loop Tick"
    assert once_text =~ "Verdict: continue"
    assert once_text =~ "Reason: still open"

    start_text =
      GoalStatusMessage.handle(session_key, "loop start --auto --max-ticks 5 --interval-ms 20",
        loop_module: FakeLoop
      )

    assert_receive {:loop_start, ^session_key, [auto: true, max_ticks: 5, interval_ms: 20]}
    assert start_text =~ "Goal Loop Started"
    assert start_text =~ "Loop status: running"

    status_text = GoalStatusMessage.handle(session_key, "loop status", loop_module: FakeLoop)
    assert_receive {:loop_status, ^session_key}
    assert status_text =~ "Goal Loop Status"
    assert status_text =~ "Running: true"

    stop_text = GoalStatusMessage.handle(session_key, "loop stop", loop_module: FakeLoop)
    assert_receive {:loop_stop, ^session_key}
    assert stop_text =~ "Goal Loop Stopped"
  end

  test "recognizes telegram goal command for bot" do
    assert Commands.goal_command?("/goal", "lemon_bot")
    assert Commands.goal_command?("/goal@lemon_bot", "lemon_bot")
    refute Commands.goal_command?("/goal@other_bot", "lemon_bot")
  end

  defp session_key do
    "goal-status-test:#{System.unique_integer([:positive])}"
  end
end
