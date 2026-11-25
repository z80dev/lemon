defmodule CodingAgent.Executor.RemoteEventCodecTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Executor.RemoteEventCodec
  alias CodingAgent.Executor.Event

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

  test "oversized deltas split at UTF-8 boundaries into events within the budget" do
    text = "start " <> String.duplicate("é€😀", 20_000) <> " end"
    budget = 4_096

    texts =
      Stream.unfold(text, fn
        "" ->
          nil

        rest ->
          assert {:ok, event, rest} = RemoteEventCodec.take_delta(rest, budget)
          assert byte_size(Jason.encode!(event)) <= budget
          assert {:ok, {:delta, chunk}} = RemoteEventCodec.decode(event)
          assert String.valid?(chunk)
          {chunk, rest}
      end)
      |> Enum.to_list()

    assert length(texts) > 1
    assert Enum.join(texts) == text

    # JSON escaping can make the encoded text wider than its byte count.
    escaped = String.duplicate(<<1>>, 1_000)
    assert {:ok, event, rest} = RemoteEventCodec.take_delta(escaped, 512)
    assert byte_size(Jason.encode!(event)) <= 512
    assert byte_size(rest) > 0

    assert {:error, {:max_bytes, _}} = RemoteEventCodec.take_delta("😀", 8)
  end

  test "oversized action detail is elided to the budget, keeping identity" do
    content = String.duplicate("a", 128 * 1_024)

    action =
      Event.action_event(%{
        engine: "lemon",
        phase: :completed,
        ok: true,
        message: String.duplicate("m", 100 * 1_024),
        action:
          Event.action(%{
            id: "tool_call-1",
            kind: "file_change",
            title: "Write big.txt",
            detail: %{
              name: "write",
              tool_call_id: "call-1",
              args: %{"path" => "big.txt", "content" => content},
              result_full: content,
              details: %{diff: content, lines: Enum.to_list(1..20_000)}
            }
          })
      })

    assert {:ok, wire} = RemoteEventCodec.encode_engine(action)
    assert byte_size(Jason.encode!(wire)) <= RemoteEventCodec.max_bytes()
    detail = wire["action"]["detail"]
    assert detail["args"]["path"] == "big.txt"
    assert detail["args"]["content"] =~ "bytes omitted"
    assert detail["result_full"] =~ "bytes omitted"
    assert is_list(detail["details"]["lines"])
    assert {:ok, {:engine, %{action: %{id: "tool_call-1"}}}} = RemoteEventCodec.decode(wire)

    # A budget below any elided projection (here: wide keys survive every
    # collection limit) keeps only the identifying fields.
    wide_keys = Map.new(1..5, &{String.duplicate("k", 200) <> "#{&1}", "v"})
    action = update_in(action.action.detail, &Map.merge(&1, wide_keys))
    action = %{action | message: nil}
    assert {:ok, wire} = RemoteEventCodec.encode_engine(action, 300)
    assert byte_size(Jason.encode!(wire)) <= 300

    assert wire["action"]["detail"] == %{
             "elided" => true,
             "name" => "write",
             "tool_call_id" => "call-1"
           }

    assert {:ok, {:engine, _}} = RemoteEventCodec.decode(wire)
  end

  test "oversized checkpoint path lists are elided, never rejected" do
    paths = Enum.map(1..20_000, &"dir/file-#{&1}.txt")

    assert {:ok, wire} =
             RemoteEventCodec.encode_checkpoint(:checkpoint_created, %{
               checkpoint_id: "cp-1",
               path_count: 20_000,
               paths: paths
             })

    assert wire["checkpointId"] == "cp-1"
    assert wire["pathCount"] == 20_000
    assert length(wire["paths"]) < 20_000
    assert {:ok, {:checkpoint, :checkpoint_created, _}} = RemoteEventCodec.decode(wire)
  end

  test "approval requests are refused rather than elided" do
    pending = %{
      id: "approval-big",
      tool: "bash",
      action: %{"command" => String.duplicate("x", RemoteEventCodec.max_bytes())},
      rationale: nil,
      expires_at_ms: nil,
      once_only: true
    }

    assert {:error, {:max_bytes, _}} = RemoteEventCodec.encode_approval(pending)
  end

  test "approval requests carry a required boolean onceOnly flag" do
    pending = %{
      id: "approval-1",
      tool: "computer",
      action: %{"type" => "click"},
      rationale: nil,
      expires_at_ms: nil,
      once_only: true
    }

    assert {:ok, wire} = RemoteEventCodec.encode_approval(pending)
    assert wire["onceOnly"] == true
    assert {:ok, {:approval, %{once_only: true}}} = RemoteEventCodec.decode(wire)

    assert {:ok, wire} = RemoteEventCodec.encode_approval(%{pending | once_only: false})
    assert {:ok, {:approval, %{once_only: false}}} = RemoteEventCodec.decode(wire)

    # A dropped or forged flag is rejected, never read as "not once-only".
    for bad <- [Map.delete(wire, "onceOnly"), Map.put(wire, "onceOnly", "true")] do
      assert {:error, :invalid_approval} = RemoteEventCodec.decode(bad)
    end
  end
end
