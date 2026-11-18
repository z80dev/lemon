defmodule LemonChannels.Adapters.Email.ThreadStoreTest do
  @moduledoc """
  The thread state the port added, and the case that justifies it.

  `LemonChannels.Adapters.Email.thread_id/1` alone is correct for a chain whose
  messages arrive in order and name every ancestor. These tests cover what it
  cannot do — join a chain whose middle message arrives first — and what
  outbound needs from it, and that every row stays owned by the inbox and
  sender that wrote it.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Email
  alias LemonChannels.Adapters.Email.{Outbound, ThreadStore}
  alias LemonChannels.OutboundPayload

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"

  defp ingest(raw) do
    {:ok, message} = Email.normalize_inbound(raw)
    message
  end

  defp scope_of(message), do: ThreadStore.scope(message.account_id, message.sender.id)

  defp state_of(message), do: ThreadStore.state(scope_of(message), message.peer.thread_id)

  describe "scope/2" do
    test "normalizes the inbox and sender and requires both" do
      assert ThreadStore.scope(" Agent@Lemon.test ", "A@B.test") ==
               {"agent@lemon.test", "a@b.test"}

      assert ThreadStore.scope(nil, "a@b.test") == nil
      assert ThreadStore.scope("agent@lemon.test", " ") == nil
    end
  end

  describe "resolve/3" do
    test "returns the stateless id for a message with no known ancestor" do
      parsed = Email.parse(%{"from" => "a@b.test", "message_id" => "<#{unique("solo")}>"})

      assert ThreadStore.resolve(parsed, "fallback", ThreadStore.scope("email", "a@b.test")) ==
               "fallback"
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

      assert ThreadStore.resolve(reply, "would-be-wrong", scope_of(first)) ==
               first.peer.thread_id
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

    test "nothing resolves without a scope" do
      root = unique("root")
      ingest(%{"from" => "a@b.test", "message_id" => "<#{root}>"})
      parsed = Email.parse(%{"from" => "a@b.test", "in_reply_to" => "<#{root}>"})

      assert ThreadStore.resolve(parsed, "fallback", nil) == "fallback"
    end
  end

  describe "record_inbound/3" do
    test "keeps the subject and the reference chain a reply needs" do
      root = unique("root")

      message =
        ingest(%{
          "from" => "a@b.test",
          "to" => "agent@lemon.test",
          "subject" => "Quarterly numbers",
          "message_id" => "<#{root}>"
        })

      state = state_of(message)

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

      state = state_of(first)

      assert state["references"] == [root, reply]
      assert state["last_message_id"] == reply
    end

    test "an unknown thread reads as empty rather than raising" do
      scope = ThreadStore.scope("email", "a@b.test")
      assert ThreadStore.state(scope, "no-such-thread") == %{}
      assert ThreadStore.state(scope, nil) == %{}
      assert ThreadStore.state(nil, "no-such-thread") == %{}
    end
  end

  describe "record_outbound/4" do
    test "makes a reply to our own message resolve to the same thread" do
      root = unique("root")
      sent = unique("sent")

      first = ingest(%{"from" => "a@b.test", "subject" => "hi", "message_id" => "<#{root}>"})
      :ok = ThreadStore.record_outbound(scope_of(first), first.peer.thread_id, sent, [root])

      answer =
        ingest(%{
          "from" => "a@b.test",
          "subject" => "Re: hi",
          "message_id" => "<#{unique("answer")}>",
          "in_reply_to" => "<#{sent}>"
        })

      assert answer.peer.thread_id == first.peer.thread_id
      assert sent in state_of(first)["references"]
    end

    test "is a no-op without a thread id or a scope, since there is nothing to key on" do
      assert ThreadStore.record_outbound(ThreadStore.scope("email", "a@b.test"), nil, "x@y", []) ==
               :ok

      assert ThreadStore.record_outbound(nil, "thread@x", "x@y", []) == :ok
    end
  end

  describe "isolation between senders and inboxes" do
    # A second sender who learns one of the owner's Message-IDs (they leak via
    # forwards, Cc and quoting) must not join that thread, read its metadata
    # through the agent's reply, or overwrite it.
    setup do
      root = unique("owner-root")
      middle = unique("owner-middle")

      # Seeded out of order so the owner's thread id ("root") differs from the
      # stateless id a reply naming only `middle` would compute.
      owner =
        ingest(%{
          "from" => "owner@example.com",
          "to" => "agent@lemon.test",
          "subject" => "Acquisition plan",
          "message_id" => "<#{middle}>",
          "references" => "<#{root}>"
        })

      %{owner: owner, root: root, middle: middle}
    end

    test "another sender naming the owner's message ids starts their own thread", %{
      owner: owner,
      middle: middle
    } do
      before = state_of(owner)

      intruder =
        ingest(%{
          "from" => "mallory@example.com",
          "to" => "agent@lemon.test",
          "subject" => "pwned",
          "message_id" => "<#{unique("mallory")}>",
          "in_reply_to" => "<#{middle}>"
        })

      refute intruder.peer.thread_id == owner.peer.thread_id
      assert state_of(owner) == before

      # Same thread id string, different owner: still nothing of the owner's.
      assert ThreadStore.state(scope_of(intruder), owner.peer.thread_id) == %{}
    end

    test "another sender reusing the owner's thread id cannot read or poison its state", %{
      owner: owner,
      root: root,
      middle: middle
    } do
      before = state_of(owner)

      # Naming the owner's root in References yields the same stateless thread
      # id string; the state behind it must still be the intruder's own.
      intruder =
        ingest(%{
          "from" => "mallory@example.com",
          "to" => "agent@lemon.test",
          "message_id" => "<#{unique("mallory")}>",
          "references" => "<#{root}>"
        })

      assert intruder.peer.thread_id == owner.peer.thread_id
      assert state_of(owner) == before
      assert state_of(intruder)["subject"] == nil
      refute middle in state_of(intruder)["references"]

      payload =
        OutboundPayload.new(
          channel_id: "email",
          account_id: intruder.account_id,
          peer: %{kind: :dm, id: "mallory@example.com", thread_id: intruder.peer.thread_id},
          kind: :text,
          content: "reply"
        )

      assert {:ok, envelope} = Outbound.build_envelope(payload, %{})
      assert envelope.subject == "Re: (no subject)"
      refute middle in envelope.references
      assert envelope.to == "mallory@example.com"

      owner_payload = %{payload | peer: %{payload.peer | id: "owner@example.com"}}
      assert {:ok, owner_envelope} = Outbound.build_envelope(owner_payload, %{})
      assert owner_envelope.subject == "Re: Acquisition plan"
      assert middle in owner_envelope.references
    end

    test "the same sender writing to another inbox does not join or read the first inbox's thread",
         %{owner: owner, middle: middle} do
      other_inbox =
        ingest(%{
          "from" => "owner@example.com",
          "to" => "billing@lemon.test",
          "message_id" => "<#{unique("other-inbox")}>",
          "in_reply_to" => "<#{middle}>"
        })

      refute other_inbox.peer.thread_id == owner.peer.thread_id
      assert state_of(other_inbox)["subject"] == nil
      assert ThreadStore.state(scope_of(other_inbox), owner.peer.thread_id) == %{}
      assert state_of(owner)["subject"] == "Acquisition plan"
    end

    test "unowned legacy rows are never adopted just because an id matches" do
      legacy_message = unique("legacy-message")
      legacy_thread = "legacy-thread-#{System.unique_integer([:positive])}"

      :ok =
        LemonCore.Store.put(:email_message_threads, legacy_message, %{
          "thread_id" => legacy_thread
        })

      :ok =
        LemonCore.Store.put(:email_thread_state, legacy_thread, %{
          "thread_id" => legacy_thread,
          "subject" => "legacy secret",
          "references" => [legacy_message]
        })

      reply =
        ingest(%{
          "from" => "owner@example.com",
          "to" => "agent@lemon.test",
          "message_id" => "<#{unique("after-upgrade")}>",
          "in_reply_to" => "<#{legacy_message}>"
        })

      refute reply.peer.thread_id == legacy_thread
      assert ThreadStore.state(scope_of(reply), legacy_thread) == %{}
      assert state_of(reply)["subject"] == nil
    end
  end
end
