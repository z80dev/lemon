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
  alias LemonCore.ResumeToken, as: GatewayToken

  test "maps claude started/completed events" do
    token = ResumeToken.new("claude", "sess_abc")
    started = StartedEvent.new("claude", token)
    completed = CompletedEvent.ok("claude", "answer", resume: token)

    started_result = CliAdapter.to_event_map(started)
    assert %{__event__: :started, engine: "claude", resume: %GatewayToken{value: "sess_abc"}} = started_result

    completed_result = CliAdapter.to_event_map(completed)

    assert %{
             __event__: :completed,
             engine: "claude",
             ok: true,
             answer: "answer",
             resume: %GatewayToken{value: "sess_abc"}
           } = completed_result
  end

  test "maps claude action events" do
    action = Action.new("t1", :tool, "Bash", %{})
    ev = ActionEvent.new("claude", action, :completed, ok: true)

    result = CliAdapter.to_event_map(ev)

    assert %{
             __event__: :action_event,
             engine: "claude",
             action: %{__event__: :action, id: "t1", kind: "tool"},
             phase: :completed
           } = result
  end
end
