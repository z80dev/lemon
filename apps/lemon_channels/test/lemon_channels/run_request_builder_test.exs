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
