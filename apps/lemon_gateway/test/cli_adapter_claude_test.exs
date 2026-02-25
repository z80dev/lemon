defmodule LemonGateway.CliAdapterClaudeTest do
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
  alias LemonCore.ResumeToken, as: GatewayToken

  test "maps claude started/completed events" do
    token = ResumeToken.new("claude", "sess_abc")
    started = StartedEvent.new("claude", token)
    completed = CompletedEvent.ok("claude", "answer", resume: token)

    %Event.Started{engine: "claude", resume: %GatewayToken{value: "sess_abc"}} =
      CliAdapter.to_gateway_event(started)

    %Event.Completed{
      engine: "claude",
      ok: true,
      answer: "answer",
      resume: %GatewayToken{value: "sess_abc"}
    } =
      CliAdapter.to_gateway_event(completed)
  end

  test "maps claude action events" do
    action = Action.new("t1", :tool, "Bash", %{})
    ev = ActionEvent.new("claude", action, :completed, ok: true)

    %Event.ActionEvent{
      engine: "claude",
      action: %Event.Action{id: "t1", kind: "tool"},
      phase: :completed
    } =
      CliAdapter.to_gateway_event(ev)
  end
end
