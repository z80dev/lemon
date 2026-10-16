defmodule LemonChannels.Adapters.Telegram.ApprovalRequestTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.{ApprovalRequest, CallbackHandler}
  alias LemonChannels.{OutboundPayload, RemoteApproval, Supervision}
  alias LemonCore.{ExecApprovalStore, SessionKey}
  alias LemonCore.Events.ApprovalPending

  defmodule API do
    def answer_callback_query(_token, id, opts) do
      send(self(), {:answer, id, opts["text"]})
      :ok
    end
  end

  setup do
    id = LemonCore.Id.approval_id()

    target = %{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :group, id: "-1003842984060", thread_id: "35"}
    }

    session =
      SessionKey.channel_peer(%{
        agent_id: "test",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :group,
        peer_id: target.peer.id,
        thread_id: "35"
      })

    pending =
      ApprovalPending.new(%{
        id: id,
        run_id: "run_#{id}",
        session_key: session,
        tool: "bash",
        action: %{command: "echo APPROVED"},
        requested_at_ms: LemonCore.Clock.now_ms()
      })

    :ok = ExecApprovalStore.put_pending(id, pending)
    on_exit(fn -> ExecApprovalStore.delete_pending(id) end)

    state = %{
      account_id: "default",
      api_mod: API,
      token: "fake",
      allowed_chat_ids: [-1_003_842_984_060],
      deny_unbound_chats: false
    }

    cb = %{
      "id" => "callback",
      "data" => RemoteApproval.callback(pending, :approve_once),
      "message" => %{
        "message_id" => 123,
        "message_thread_id" => 35,
        "chat" => %{"id" => -1_003_842_984_060, "type" => "supergroup"}
      }
    }

    enqueue = fn payload ->
      send(self(), {:queued, payload})
      {:ok, make_ref()}
    end

    %{pending: pending, target: target, state: state, cb: cb, opts: [enqueue: enqueue]}
  end

  test "request queues exact ID, snapshot, account and topic with only once/deny", c do
    assert :ok =
             ApprovalRequest.send(
               c.state,
               %{approval_id: c.pending.id, pending: c.pending},
               c.opts
             )

    assert_receive {:queued,
                    %OutboundPayload{
                      kind: :text,
                      channel_id: "telegram",
                      account_id: "default",
                      peer: peer,
                      meta: %{reply_markup: markup},
                      content: text
                    }}

    assert peer == c.target.peer
    assert text =~ "Action: echo APPROVED"
    assert %{"inline_keyboard" => [[approve, deny]]} = markup
    assert approve["callback_data"] == c.cb["data"]
    assert byte_size(approve["callback_data"]) <= 64
    assert {:ok, id, _, :deny} = RemoteApproval.parse(deny["callback_data"])
    assert id == c.pending.id
  end

  test "automation child resolves its immutable run/session binding", c do
    child = %{c.pending | session_key: "agent:test:child:#{c.pending.id}"}
    :ok = ExecApprovalStore.delete_pending(child.id)
    :ok = ExecApprovalStore.put_pending(child.id, child)
    assert :ok = Supervision.bind_run(child.run_id, child.session_key, c.target)
    assert :ok = ApprovalRequest.send(c.state, %{approval_id: child.id, pending: child}, c.opts)
    assert_receive {:queued, %OutboundPayload{peer: peer}}
    assert peer == c.target.peer
    wrong_session = %{child | session_key: "agent:other:main"}
    :ok = ExecApprovalStore.delete_pending(child.id)
    :ok = ExecApprovalStore.put_pending(child.id, wrong_session)

    assert {:error, _} =
             ApprovalRequest.send(
               c.state,
               %{approval_id: child.id, pending: wrong_session},
               c.opts
             )

    refute_receive {:queued, _}
  end

  test "success consumes once and queues edit; replay never claims success", c do
    assert :ok = ApprovalRequest.handle_callback(c.state, c.cb, c.opts)
    assert_receive {:answer, "callback", "Recorded"}

    assert_receive {:queued,
                    %OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "123"},
                      meta: %{reply_markup: %{"inline_keyboard" => []}}
                    }}

    assert {:ok, nil} = ExecApprovalStore.fetch_pending(c.pending.id)
    assert :ok = ApprovalRequest.handle_callback(c.state, c.cb, c.opts)
    assert_receive {:answer, "callback", answer}
    refute answer == "Recorded"
    refute_receive {:queued, _}
  end

  test "click on an expired approval edits the prompt, answers expired and approves nothing", c do
    expire(c.pending)
    opts = Keyword.put(c.opts, :resolve, fn _, _, _ -> flunk("must not resolve") end)

    assert :ok = ApprovalRequest.handle_callback(c.state, c.cb, opts)
    assert_receive {:answer, "callback", "Approval expired: the run ended; nothing was approved"}

    assert_receive {:queued,
                    %OutboundPayload{
                      kind: :edit,
                      content: %{message_id: "123", text: "Approval: Expired (the run ended)"},
                      meta: %{reply_markup: %{"inline_keyboard" => []}}
                    }}

    refute_receive {:queued, _}
  end

  test "click on a non-expired terminal approval keeps the generic answer", c do
    :ok = ExecApprovalStore.delete_pending(c.pending.id)

    :ok =
      ExecApprovalStore.put_pending(c.pending.id, %{
        resolution: %{approval_id: c.pending.id, outcome: :denied, decision: :deny}
      })

    assert :ok = ApprovalRequest.handle_callback(c.state, c.cb, c.opts)
    assert_receive {:answer, "callback", "Approval rejected or unavailable; request unchanged"}
    refute_receive {:queued, _}
  end

  test "click on an expired approval from a foreign chat never edits", c do
    expire(c.pending)
    foreign = put_in(c.cb, ["message", "chat", "id"], -1_000_000_000_001)

    assert :ok = ApprovalRequest.handle_callback(c.state, foreign, c.opts)
    assert_receive {:answer, "callback", "Approval rejected or unavailable; request unchanged"}
    refute_receive {:queued, _}
  end

  test "cross-chat/thread/account, malformed IDs and unauthorized callbacks preserve request",
       c do
    callbacks = [
      put_in(c.cb, ["message", "chat", "id"], -999),
      put_in(c.cb, ["message", "message_thread_id"], 36),
      put_in(c.cb, ["message", "message_thread_id"], "35garbage"),
      put_in(c.cb, ["message", "chat", "type"], "private"),
      Map.put(c.cb, "data", c.pending.id <> "|once"),
      Map.put(c.cb, "data", String.replace(c.cb["data"], "|once", "|global")),
      Map.put(c.cb, "data", "prefix" <> c.cb["data"]),
      Map.put(c.cb, "data", 12)
    ]

    for cb <- callbacks do
      assert :ok = ApprovalRequest.handle_callback(c.state, cb, c.opts)
      assert_receive {:answer, _, answer}
      refute answer == "Recorded"
      assert {:ok, pending} = ExecApprovalStore.fetch_pending(c.pending.id)
      assert pending == c.pending
      refute_receive {:queued, _}
    end

    for state <- [%{c.state | account_id: "foreign"}, %{c.state | allowed_chat_ids: [999]}] do
      assert :ok = ApprovalRequest.handle_callback(state, c.cb, c.opts)
      assert_receive {:answer, _, answer}
      refute answer == "Recorded"

      assert {:error, _} =
               ApprovalRequest.send(
                 state,
                 %{approval_id: c.pending.id, pending: c.pending},
                 c.opts
               )

      refute_receive {:queued, _}
    end
  end

  test "stale payload and expired record cannot send or resolve", c do
    for replacement <- [
          %{c.pending | action: %{command: "different"}},
          %{c.pending | expires_at_ms: LemonCore.Clock.now_ms() - 1}
        ] do
      :ok = ExecApprovalStore.delete_pending(c.pending.id)
      :ok = ExecApprovalStore.put_pending(c.pending.id, replacement)

      assert {:error, _} =
               ApprovalRequest.send(
                 c.state,
                 %{approval_id: c.pending.id, pending: c.pending},
                 c.opts
               )

      assert :ok = ApprovalRequest.handle_callback(c.state, c.cb, c.opts)
      assert_receive {:answer, _, answer}
      refute answer == "Recorded"
      assert {:ok, ^replacement} = ExecApprovalStore.fetch_pending(c.pending.id)
      refute_receive {:queued, _}
    end
  end

  test "store, target, resolver failures never edit or acknowledge success", c do
    failures = [
      [fetch: fn _ -> {:error, :store_unavailable} end],
      [target: fn _, _ -> {:error, :store_unavailable} end],
      [resolve: fn _, _, _ -> {:error, :mismatch} end],
      [resolve: fn _, _, _ -> {:error, :expired} end],
      [resolve: fn _, _, _ -> {:error, :store_unavailable} end],
      [resolve: fn _, _, _ -> exit(:unavailable) end],
      [resolve: fn _, _, _ -> :unexpected end]
    ]

    for failure <- failures do
      assert :ok = ApprovalRequest.handle_callback(c.state, c.cb, Keyword.merge(c.opts, failure))
      assert_receive {:answer, _, answer}
      refute answer == "Recorded"
      assert {:ok, pending} = ExecApprovalStore.fetch_pending(c.pending.id)
      assert pending == c.pending
      refute_receive {:queued, _}
    end
  end

  test "atomic resolver receives exact fetched snapshot and rejects a concurrent replacement",
       c do
    replacement = %{c.pending | action: %{command: "replacement"}}

    resolve = fn id, decision, opts ->
      assert id == c.pending.id
      assert opts[:expected_pending] == c.pending
      :ok = ExecApprovalStore.delete_pending(id)
      :ok = ExecApprovalStore.put_pending(id, replacement)
      LemonCore.ExecApprovals.resolve(id, decision, opts)
    end

    assert :ok =
             ApprovalRequest.handle_callback(
               c.state,
               c.cb,
               Keyword.put(c.opts, :resolve, resolve)
             )

    assert_receive {:answer, _, answer}
    refute answer == "Recorded"
    assert {:ok, ^replacement} = ExecApprovalStore.fetch_pending(c.pending.id)
    refute_receive {:queued, _}
  end

  test "callback dispatcher rejects malformed approval payload without a resolver mutation", c do
    assert :ok = CallbackHandler.handle_callback_query(c.state, Map.put(c.cb, "data", nil))
    assert_receive {:answer, _, answer}
    refute answer == "Recorded"
    assert {:ok, pending} = ExecApprovalStore.fetch_pending(c.pending.id)
    assert pending == c.pending
  end

  test "Outbox rejection is returned without falling back to direct send", c do
    enqueue = fn _ -> {:error, :queue_full} end

    assert {:error, :queue_full} =
             ApprovalRequest.send(
               c.state,
               %{approval_id: c.pending.id, pending: c.pending},
               enqueue: enqueue
             )

    assert {:ok, pending} = ExecApprovalStore.fetch_pending(c.pending.id)
    assert pending == c.pending
  end

  test "prompt payload carries the tracker delivery ack without changing the result", c do
    assert :ok =
             ApprovalRequest.send(
               c.state,
               %{approval_id: c.pending.id, pending: c.pending},
               c.opts
             )

    assert_receive {:queued, %OutboundPayload{notify_pid: pid, notify_ref: ref, meta: meta}}
    assert pid == Process.whereis(LemonChannels.ApprovalPromptTracker)
    assert is_reference(ref)
    assert meta.notify_tag == LemonChannels.ApprovalPromptTracker.notify_tag()
  end

  defp expire(pending) do
    :ok = ExecApprovalStore.delete_pending(pending.id)

    :ok =
      ExecApprovalStore.put_pending(pending.id, %{
        resolution: %{
          approval_id: pending.id,
          session_key: pending.session_key,
          run_id: pending.run_id,
          decision: :expired,
          outcome: :expired,
          resolved_at_ms: 1,
          pending_hash: "x"
        }
      })
  end
end
