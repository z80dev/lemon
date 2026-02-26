alias AgentCore.Test.Mocks
alias AgentCore.Types.{AgentTool, AgentToolResult}
alias Ai.Types.{AssistantMessage, TextContent}
alias CodingAgent.{Session, SettingsManager}

defp default_settings do
  %SettingsManager{
    default_thinking_level: :off,
    compaction_enabled: false,
    reserve_tokens: 16384,
    extension_paths: [],
    providers: %{}
  }
end

slow_tool = %AgentTool{
  name: "very_slow",
  description: "Very slow tool",
  parameters: %{"type" => "object", "properties" => %{}},
  label: "Very Slow",
  execute: fn _id, _args, signal, _on_update ->
    for _ <- 1..50 do
      if AgentCore.AbortSignal.aborted?(signal) do
        throw(:aborted)
      end

      Process.sleep(20)
    end

    %AgentToolResult{
      content: [%TextContent{type: :text, text: "Never reached"}],
      details: nil
    }
  end
}

tool_call = Mocks.tool_call("very_slow", %{}, id: "call_vs")
response = Mocks.assistant_message_with_tool_calls([tool_call])

{:ok, session} = Session.start_link(
  cwd: System.tmp_dir!(),
  model: Mocks.mock_model(),
  settings_manager: default_settings(),
  system_prompt: "You are a helpful assistant.",
  tools: [slow_tool],
  stream_fn: Mocks.mock_stream_fn_single(response)
)

_unsub = Session.subscribe(session)
:ok = Session.prompt(session, "Run very slow tool")
Process.sleep(100)
:ok = Session.abort(session)

collect_events = fn events, timeout, deadline ->
  deadline = deadline || System.monotonic_time(:millisecond) + timeout
  remaining = max(0, deadline - System.monotonic_time(:millisecond))

  if remaining == 0 do
    Enum.reverse(events ++ [{:timeout, timeout}])
  else
    receive do
      {:session_event, _session_id, {:agent_end, _messages}} ->
        Enum.reverse(events ++ [{:agent_end, []}])

      {:session_event, _session_id, {:error, reason, _partial}} ->
        Enum.reverse(events ++ [{:error, reason}])

      {:session_event, _session_id, {:canceled, reason}} ->
        Enum.reverse(events ++ [{:canceled, reason}])

      {:session_event, _session_id,
       {:turn_end, %AssistantMessage{stop_reason: :aborted} = message, messages}} ->
        Enum.reverse(events ++ [{:turn_end, message, messages}])

      {:session_event, _session_id, event} ->
        collect_events.(events ++ [event], timeout, deadline)
    after
      remaining ->
        Enum.reverse(events ++ [{:timeout, timeout}])
    end
  end
end

events = collect_events.([], 5000, nil)
IO.inspect(events, label: "Observed events")
