defmodule CodingAgent.ToolIntentTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.MessageSerialization
  alias CodingAgent.{SessionManager, ToolExecutor, ToolPolicy}
  alias LemonAgent.{EventStream, ToolIntent}
  alias LemonAgent.Loop.ToolCalls
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAi.Types.{AssistantMessage, ToolCall}

  test "ask approvals receive intent, never as execution input, and persistence retains model arguments" do
    parent = self()
    intent = "Writing model role settings. "
    arguments = %{"path" => "settings.json", "i" => intent}
    call = %ToolCall{id: "write-settings", name: "write", arguments: arguments}
    message = %AssistantMessage{content: [call], stop_reason: :tool_use}

    tool = %AgentTool{
      name: "write",
      parameters: %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"],
        "additionalProperties" => false
      },
      execute: fn _, args, _, _ ->
        send(parent, {:executed, args, ToolIntent.current()})
        %AgentToolResult{content: []}
      end
    }

    context = %{
      session_id: "intent-test",
      approval_request_fun: fn request ->
        send(parent, {:approval, request})
        {:ok, :approved, :once}
      end
    }

    wrapped =
      ToolExecutor.wrap_with_approval(tool, ToolPolicy.parse!(%{approval_mode: :ask}), context)

    {:ok, stream} = EventStream.start_link(timeout: :infinity)

    {[result], [], updated, _} =
      ToolCalls.execute_and_collect_tools(
        AgentContext.new(tools: [wrapped], messages: [message]),
        [message],
        [call],
        %AgentLoopConfig{},
        nil,
        stream
      )

    refute result.is_error
    assert_receive {:approval, request}
    assert request.rationale == intent
    assert request.tool_call_id == call.id
    assert request.action == %{"path" => "settings.json"}
    assert_receive {:executed, %{"path" => "settings.json"}, ^intent}
    assert hd(updated.messages) == message
    EventStream.complete(stream, [])

    assert {:tool_execution_start, call.id, "write", arguments} in Enum.to_list(
             EventStream.events(stream)
           )

    directory = Path.join(System.tmp_dir!(), "tool-intent-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "session.jsonl")
    serialized = MessageSerialization.serialize_message(hd(updated.messages))
    session = SessionManager.append_message(SessionManager.new(directory), serialized)
    assert :ok = SessionManager.save_to_file(path, session)
    assert {:ok, restored} = SessionManager.load_from_file(path)
    [entry] = SessionManager.entries(restored)
    restored_message = MessageSerialization.deserialize_message(entry.message)
    assert hd(restored_message.content).arguments == arguments
  end

  test "approval rationale keeps its fallback without intent" do
    ToolExecutor.execute_with_approval("write", %{}, fn -> %AgentToolResult{} end, %{
      approval_request_fun: fn request ->
        assert request.rationale == "Tool execution: write"
        {:ok, :approved, :once}
      end
    })
  end
end
