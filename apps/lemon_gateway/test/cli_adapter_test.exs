defmodule LemonGateway.CliAdapterTest do
  use ExUnit.Case

  alias AgentCore.CliRunners.Types.{
    Action,
    ActionEvent,
    CompletedEvent,
    ResumeToken,
    StartedEvent
  }

  alias LemonGateway.Engines.CliAdapter
  alias LemonCore.ResumeToken, as: GatewayToken

  test "maps started event" do
    token = ResumeToken.new("codex", "thread_123")
    ev = StartedEvent.new("codex", token, title: "Codex")

    result = CliAdapter.to_event_map(ev)
    assert %{__event__: :started, engine: "codex", resume: %GatewayToken{value: "thread_123"}} = result
  end

  test "maps action event" do
    action = Action.new("a1", :command, "ls -la", %{})
    ev = ActionEvent.new("codex", action, :started, level: :info)

    result = CliAdapter.to_event_map(ev)

    assert %{
             __event__: :action_event,
             engine: "codex",
             action: %{__event__: :action, id: "a1", kind: "command"},
             phase: :started
           } = result
  end

  test "maps completed event" do
    token = ResumeToken.new("codex", "thread_123")
    ev = CompletedEvent.ok("codex", "done", resume: token)

    result = CliAdapter.to_event_map(ev)
    assert %{__event__: :completed, ok: true, answer: "done", resume: %GatewayToken{value: "thread_123"}} = result
  end

  test "cancel uses cancel/2 when runner exports it" do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          {:cancel_reason, reason} -> send(parent, {:cancel_reason_seen, reason})
        end
      end)

    defmodule CliAdapterCancel2Runner do
      def cancel(pid, reason), do: send(pid, {:cancel_reason, reason})
    end

    ctx = %{runner_pid: pid, task_pid: nil, runner_module: CliAdapterCancel2Runner}
    assert :ok = CliAdapter.cancel(ctx)
    assert_receive {:cancel_reason_seen, :user_requested}, 1_000
  end

  test "cancel falls back to cancel/1 when runner only exports arity 1" do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :cancel_called -> send(parent, :cancel_arity_1_seen)
        end
      end)

    defmodule CliAdapterCancel1Runner do
      def cancel(pid), do: send(pid, :cancel_called)
    end

    ctx = %{runner_pid: pid, task_pid: nil, runner_module: CliAdapterCancel1Runner}
    assert :ok = CliAdapter.cancel(ctx)
    assert_receive :cancel_arity_1_seen, 1_000
  end
end
