defmodule CodingAgent.Executor.RemoteEventCodecTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Executor.RemoteEventCodec
  alias LemonGateway.Event

  test "live lifecycle fields are allowlisted and round-trip without credentials or runtime state" do
    event =
      Event.started(%{
        engine: "lemon",
        resume: nil,
        meta: %{mcp_servers: [%{headers: %{authorization: "secret"}}]}
      })

    assert {:ok, %{"type" => "started", "title" => nil} = wire} =
             RemoteEventCodec.encode_engine(event)

    refute inspect(wire) =~ "secret"

    assert {:ok, {:engine, %{__event__: :started, engine: "lemon", meta: nil}}} =
             RemoteEventCodec.decode(wire)

    action =
      Event.action_event(%{
        engine: "lemon",
        phase: :completed,
        ok: true,
        message: "done",
        action:
          Event.action(%{id: "tool", kind: "bash", title: "Command", detail: %{exit_code: 0}})
      })

    assert {:ok, wire} = RemoteEventCodec.encode_engine(action)

    assert {:ok,
            {:engine,
             %{
               __event__: :action_event,
               phase: :completed,
               ok: true,
               action: %{detail: %{"exit_code" => 0}}
             }}} =
             RemoteEventCodec.decode(wire)

    assert :ignore = RemoteEventCodec.encode_engine(Event.completed(%{engine: "lemon", ok: true}))
  end

  test "streaming tool results retain visible typed content but not hidden state" do
    partial = %LemonAgent.Types.AgentToolResult{
      content: [
        %LemonAi.Types.TextContent{text: "visible", text_signature: "signature"},
        %LemonAi.Types.ThinkingContent{thinking: "private"}
      ],
      details: %{exit_code: 0, callback: fn -> :private end}
    }

    event =
      Event.action_event(%{
        engine: "lemon",
        phase: :updated,
        action:
          Event.action(%{
            id: "tool",
            kind: "bash",
            title: "Command",
            detail: %{partial_result: partial}
          })
      })

    assert {:ok, wire} = RemoteEventCodec.encode_engine(event)
    result = get_in(wire, ["action", "detail", "partial_result"])
    assert result["content"] == [%{"type" => "text", "text" => "visible"}]
    assert result["details"] == %{"exit_code" => 0}
    refute inspect(wire) =~ "private"
    refute inspect(wire) =~ "signature"
  end

  test "checkpoint payloads use the existing core event names and exclude arbitrary fields" do
    assert {:ok, wire} =
             RemoteEventCodec.encode_checkpoint(
               :checkpoint_created,
               %{checkpoint_id: "cp-1", paths: ["file.txt"], secret: "excluded"}
             )

    refute Map.has_key?(wire, "secret")

    assert {:ok,
            {:checkpoint, :checkpoint_created, %{checkpoint_id: "cp-1", paths: ["file.txt"]}}} =
             RemoteEventCodec.decode(wire)

    assert {:error, :invalid_event} = RemoteEventCodec.decode(%{"type" => "checkpoint_unknown"})
  end

  test "invalid phases, non-JSON runtime values, depth, and bytes are rejected" do
    assert {:error, :invalid_event} =
             RemoteEventCodec.decode(%{
               "type" => "action",
               "phase" => "not-an-atom",
               "action" => %{}
             })

    assert {:error, {:not_json_safe, _}} = RemoteEventCodec.encode_delta(self())

    assert {:error, {:max_bytes, _}} =
             RemoteEventCodec.encode_delta(String.duplicate("x", RemoteEventCodec.max_bytes()))

    deep = Enum.reduce(1..40, "text", fn _, inner -> %{"nested" => inner} end)

    assert {:error, {:max_depth, _}} =
             RemoteEventCodec.decode(%{"type" => "started", "title" => deep})
  end
end
