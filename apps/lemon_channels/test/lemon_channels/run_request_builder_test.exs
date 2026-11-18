defmodule LemonChannels.RunRequestBuilderTest do
  use ExUnit.Case, async: true

  alias LemonChannels.RunRequestBuilder
  alias LemonCore.{InboundMessage, ResumeToken}

  test "accepts only native resume tokens at the channel boundary" do
    native = %ResumeToken{engine: "lemon", value: "session-123"}
    vendor = %ResumeToken{engine: "codex", value: "thread-456"}

    assert RunRequestBuilder.from_inbound(inbound(native)).resume == native
    assert RunRequestBuilder.from_inbound(inbound(vendor)).resume == nil

    assert RunRequestBuilder.from_inbound(
             inbound(%{"engine" => "lemon", "value" => "session-789"})
           ).resume ==
             %ResumeToken{engine: "lemon", value: "session-789"}

    assert RunRequestBuilder.from_inbound(inbound(%{engine: "claude", value: "thread-999"})).resume ==
             nil
  end

  test "derives channel context and sender identity from the transport, never caller meta" do
    msg = %InboundMessage{
      channel_id: "telegram",
      account_id: "bot-a",
      peer: %{kind: :group, id: "-100", thread_id: "7"},
      sender: %{id: "42", bot: false, owner?: true},
      message: %{id: "1", text: "hi", timestamp: 0, reply_to_id: nil},
      meta: %{
        :channel_context => %{channel_id: "forged", peer_kind: :dm},
        "channel_context" => %{"peer_kind" => "dm"},
        :channel_identity => %{owner?: true, sender_id: "other"},
        "channel_identity" => %{"owner?" => true}
      }
    }

    meta = RunRequestBuilder.from_inbound(msg).meta

    assert meta.channel_context == %{
             channel_id: "telegram",
             account_id: "bot-a",
             peer_kind: :group,
             peer_id: "-100",
             thread_id: "7"
           }

    assert meta.channel_identity == %{
             channel_id: "telegram",
             sender_id: "42",
             is_bot: false,
             owner?: true,
             verified?: true
           }

    refute Map.has_key?(meta, "channel_context")
    refute Map.has_key?(meta, "channel_identity")
  end

  test "a sender without a transport id gets an unverified per-peer identity" do
    meta = RunRequestBuilder.from_inbound(inbound(nil)).meta

    assert meta.channel_identity == %{
             channel_id: "test",
             sender_id: "unidentified:dm:peer-1",
             is_bot: false,
             owner?: false,
             verified?: false
           }

    assert meta.channel_context.peer_kind == :dm
  end

  test "resolve_session_key/2 uses a valid explicit meta.session_key" do
    key = "agent:default:telegram:default:dm:123:sub:999"
    msg = %{inbound(nil) | channel_id: "telegram", peer: %{kind: :dm, id: "123", thread_id: nil}}

    assert RunRequestBuilder.resolve_session_key(%{msg | meta: %{session_key: key}}) == key

    assert RunRequestBuilder.resolve_session_key(%{msg | meta: %{session_key: "not:a:valid:key"}}) ==
             "agent:default:telegram:default:dm:123"
  end

  defp inbound(resume) do
    %InboundMessage{
      channel_id: "test",
      account_id: "default",
      peer: %{kind: :dm, id: "peer-1", thread_id: nil},
      message: %{id: "message-1", text: "hello", timestamp: 0, reply_to_id: nil},
      meta: %{resume: resume}
    }
  end
end
