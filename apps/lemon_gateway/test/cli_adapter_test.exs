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
  alias LemonGateway.Event
  alias LemonGateway.Types.ResumeToken, as: GatewayToken

  test "maps started event" do
    token = ResumeToken.new("codex", "thread_123")
    ev = StartedEvent.new("codex", token, title: "Codex")

    %Event.Started{engine: "codex", resume: %GatewayToken{value: "thread_123"}} =
      CliAdapter.to_gateway_event(ev)
  end

  test "maps action event" do
    action = Action.new("a1", :command, "ls -la", %{})
    ev = ActionEvent.new("codex", action, :started, level: :info)

    %Event.ActionEvent{
      engine: "codex",
      action: %Event.Action{id: "a1", kind: "command"},
      phase: :started
    } =
      CliAdapter.to_gateway_event(ev)
  end

  test "maps completed event" do
    token = ResumeToken.new("codex", "thread_123")
    ev = CompletedEvent.ok("codex", "done", resume: token)

    %Event.Completed{ok: true, answer: "done", resume: %GatewayToken{value: "thread_123"}} =
      CliAdapter.to_gateway_event(ev)
  end
end
