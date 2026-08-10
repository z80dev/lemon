defmodule LemonChannels.Adapters.Email.ThreadStoreTest do
  @moduledoc """
  The thread state the port added, and the case that justifies it.

  `LemonChannels.Adapters.Email.thread_id/1` alone is correct for a chain whose
  messages arrive in order and name every ancestor. These tests cover what it
  cannot do — join a chain whose middle message arrives first — and what
  outbound needs from it.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Email
  alias LemonChannels.Adapters.Email.ThreadStore

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"

  defp ingest(raw) do
    {:ok, message} = Email.normalize_inbound(raw)
    message
  end

  describe "resolve/2" do
    test "returns the stateless id for a message with no known ancestor" do
      parsed = Email.parse(%{"from" => "a@b.test", "message_id" => "<#{unique("solo")}>"})

      assert ThreadStore.resolve(parsed, "fallback") == "fallback"
    end

    test "joins the thread of a known ancestor" do
      root = unique("root")
      first = ingest(%{"from" => "a@b.test", "subject" => "hi", "message_id" => "<#{root}>"})

      reply =
        Email.parse(%{
          "from" => "a@b.test",
          "message_id" => "<#{unique("reply")}>",
          "in_reply_to" => "<#{root}>"
        })

      assert ThreadStore.resolve(reply, "would-be-wrong") == first.peer.thread_id
    end

    test "stitches a chain whose middle message arrives first" do
      # This is the case the stateless resolver gets wrong. C names A and B, so
      # it seeds a thread keyed on A. B then arrives naming only its parent A —
      # a client that trims References does this — and without the recorded
      # ancestry it would compute its own id and split the conversation.
      a = unique("a")
      b = unique("b")
      c = unique("c")

      middle_first =
        ingest(%{
          "from" => "a@b.test",
          "subject" => "long thread",
          "message_id" => "<#{c}>",
          "in_reply_to" => "<#{b}>",
          "references" => "<#{a}> <#{b}>"
        })

      trimmed =
        ingest(%{
          "from" => "a@b.test",
          "subject" => "long thread",
          "message_id" => "<#{b}>",
          "in_reply_to" => "<#{a}>"
        })

      assert trimmed.peer.thread_id == middle_first.peer.thread_id
    end

    test "a message redelivered by the provider lands on the same thread" do
      id = unique("dupe")
      raw = %{"from" => "a@b.test", "subject" => "once", "message_id" => "<#{id}>"}

      assert ingest(raw).peer.thread_id == ingest(raw).peer.thread_id
    end
  end

  describe "record_inbound/2" do
    test "keeps the subject and the reference chain a reply needs" do
      root = unique("root")

      message =
        ingest(%{
          "from" => "a@b.test",
          "to" => "agent@lemon.test",
          "subject" => "Quarterly numbers",
          "message_id" => "<#{root}>"
        })

      state = ThreadStore.state(message.peer.thread_id)

      assert state["subject"] == "Quarterly numbers"
      assert state["references"] == [root]
      assert state["last_message_id"] == root
      assert state["recipient"] == "agent@lemon.test"
    end

    test "grows the chain as the conversation continues" do
      root = unique("root")
      reply = unique("reply")

      first = ingest(%{"from" => "a@b.test", "subject" => "hi", "message_id" => "<#{root}>"})

      ingest(%{
        "from" => "a@b.test",
        "subject" => "Re: hi",
        "message_id" => "<#{reply}>",
        "in_reply_to" => "<#{root}>",
        "references" => "<#{root}>"
      })

      state = ThreadStore.state(first.peer.thread_id)

      assert state["references"] == [root, reply]
      assert state["last_message_id"] == reply
    end

    test "an unknown thread reads as empty rather than raising" do
      assert ThreadStore.state("no-such-thread") == %{}
      assert ThreadStore.state(nil) == %{}
    end
  end

  describe "record_outbound/3" do
    test "makes a reply to our own message resolve to the same thread" do
      root = unique("root")
      sent = unique("sent")

      first = ingest(%{"from" => "a@b.test", "subject" => "hi", "message_id" => "<#{root}>"})
      :ok = ThreadStore.record_outbound(first.peer.thread_id, sent, [root])

      answer =
        ingest(%{
          "from" => "a@b.test",
          "subject" => "Re: hi",
          "message_id" => "<#{unique("answer")}>",
          "in_reply_to" => "<#{sent}>"
        })

      assert answer.peer.thread_id == first.peer.thread_id
      assert sent in ThreadStore.state(first.peer.thread_id)["references"]
    end

    test "is a no-op without a thread id, since there is nothing to key on" do
      assert ThreadStore.record_outbound(nil, "some-id", []) == :ok
    end
  end
end
