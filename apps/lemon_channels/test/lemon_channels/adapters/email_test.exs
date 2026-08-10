defmodule LemonChannels.Adapters.EmailTest do
  @moduledoc """
  Inbound-half tests for the ported email adapter (Phase 2.4/B3).

  Outbound lives in `LemonChannels.Adapters.Email.OutboundTest`; the assertion
  here only covers the adapter's own promise not to raise on a payload it
  cannot make sense of.
  """
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Email
  alias LemonCore.InboundMessage

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        "from" => "Alice <ALICE@Example.com>",
        "to" => "agent@lemon.test",
        "subject" => "Status?",
        "text" => "how is it going",
        "message_id" => "<msg-1@example.com>"
      },
      overrides
    )
  end

  describe "plugin contract" do
    test "identifies itself as the email channel" do
      assert Email.id() == "email"
    end

    test "declares threading and attachments but not editing" do
      caps = Email.meta().capabilities

      assert caps.thread_support == true
      assert caps.file_support == true
      assert caps.edit_support == false
      assert caps.reaction_support == false
    end

    test "declares no chunk limit rather than inventing one" do
      assert Email.meta().capabilities.chunk_limit == nil
    end

    test "deliver/1 reports rather than raises on something that is not a payload" do
      assert {:error, :invalid_payload} = Email.deliver(%{})
    end
  end

  describe "normalize_inbound/1" do
    test "builds an InboundMessage from a provider payload" do
      assert {:ok, %InboundMessage{} = msg} = Email.normalize_inbound(payload())

      assert msg.channel_id == "email"
      assert msg.account_id == "agent@lemon.test"
      assert msg.peer.kind == :dm
      assert msg.peer.id == "alice@example.com"
      assert msg.message.text == "how is it going"
      assert msg.message.id == "msg-1@example.com"
      assert msg.meta.subject == "Status?"
    end

    test "extracts the bare address from a display-name form and lowercases it" do
      assert {:ok, msg} = Email.normalize_inbound(payload())
      assert msg.sender.id == "alice@example.com"
    end

    test "strips angle brackets from message ids" do
      {:ok, msg} = Email.normalize_inbound(payload(%{"message_id" => "<abc@x.y>"}))
      assert msg.message.id == "abc@x.y"
    end

    test "rejects a payload with no sender" do
      assert {:error, :missing_from} = Email.normalize_inbound(payload(%{"from" => "  "}))
    end

    test "rejects a non-map payload" do
      assert {:error, :invalid_payload} = Email.normalize_inbound("nope")
    end

    test "falls back to stripped HTML when there is no plain text" do
      raw = payload(%{"text" => nil, "html" => "<p>hello <b>there</b></p>"})

      {:ok, msg} = Email.normalize_inbound(raw)
      assert msg.message.text == "hello there"
    end

    test "accepts atom keys as well as string keys" do
      assert {:ok, msg} =
               Email.normalize_inbound(%{from: "bob@example.com", text: "hi", to: "a@b.c"})

      assert msg.sender.id == "bob@example.com"
      assert msg.message.text == "hi"
    end

    test "carries reply_to_id and references through" do
      raw =
        payload(%{
          "in_reply_to" => "<parent@example.com>",
          "references" => "<root@example.com> <parent@example.com>"
        })

      {:ok, msg} = Email.normalize_inbound(raw)

      assert msg.message.reply_to_id == "parent@example.com"
      assert msg.meta.references == ["root@example.com", "parent@example.com"]
    end

    test "splits a multi-recipient To into a list, keeping the first as account" do
      {:ok, msg} = Email.normalize_inbound(payload(%{"to" => "one@x.test, Two <two@x.test>"}))

      assert msg.account_id == "one@x.test"
      assert msg.meta.to == ["one@x.test", "two@x.test"]
    end
  end

  describe "thread_id/1 — the multi-ancestor case InboundMessage can't express" do
    test "prefers the oldest ancestor so a chain converges on one id" do
      parsed = Email.parse(payload(%{"references" => "<root@x.test> <mid@x.test>"}))

      assert Email.thread_id(parsed) == "root@x.test"
    end

    test "every message in a chain resolves to the same thread id" do
      first = Email.parse(payload(%{"message_id" => "<root@x.test>"}))

      reply =
        Email.parse(
          payload(%{
            "message_id" => "<reply@x.test>",
            "in_reply_to" => "<root@x.test>",
            "references" => "<root@x.test>"
          })
        )

      assert Email.thread_id(first) == Email.thread_id(reply)
    end

    test "falls back to In-Reply-To when References is absent" do
      parsed = Email.parse(payload(%{"in_reply_to" => "<parent@x.test>"}))

      assert Email.thread_id(parsed) == "parent@x.test"
    end

    test "falls back to a normalized subject when the client sends no threading headers" do
      parsed = Email.parse(%{"from" => "a@b.c", "subject" => "Re: RE: Deploy plan"})

      assert Email.thread_id(parsed) == "subject:deploy plan"
    end
  end
end
