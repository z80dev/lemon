defmodule LemonChannels.RemoteApprovalTest do
  use ExUnit.Case, async: false

  alias LemonChannels.RemoteApproval
  alias LemonCore.Events.ApprovalPending
  alias LemonCore.{ExecApprovals, ExecApprovalStore}

  setup do
    pending = pending("text_approval_#{System.unique_integer([:positive])}")

    target = %{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: "123", thread_id: nil}
    }

    :ok = ExecApprovalStore.put_pending(pending.id, pending)
    on_exit(fn -> ExecApprovalStore.delete_pending(pending.id) end)

    opts = [
      target: fn _, _ -> {:ok, target} end,
      list: fn ->
        {:ok, ExecApprovalStore.list_pending() |> Enum.filter(fn {id, _} -> id == pending.id end)}
      end
    ]

    %{pending: pending, target: target, opts: opts}
  end

  test "single latest approval consumes once, and replay is unavailable", c do
    assert {:ok, _, :approve_once} = resolve("", :approve_once, c)
    assert {:error, :not_pending} = resolve(c.pending.id, :approve_once, c)
  end

  test "full IDs and unique prefixes can deny", c do
    assert {:ok, _, :deny} = resolve(String.slice(c.pending.id, 0..-2//1), :deny, c)
    assert {:ok, nil} = ExecApprovalStore.fetch_pending(c.pending.id)
  end

  test "multiple pending approvals list unique short IDs and never guess", c do
    second = pending(c.pending.id <> "_second")
    :ok = ExecApprovalStore.put_pending(second.id, second)
    on_exit(fn -> ExecApprovalStore.delete_pending(second.id) end)

    opts =
      Keyword.put(c.opts, :list, fn -> {:ok, [{c.pending.id, c.pending}, {second.id, second}]} end)

    c = %{c | opts: opts}
    assert {:error, {:ambiguous, ids}} = resolve("", :approve_once, c)
    assert length(ids) == 2
    assert length(Enum.uniq(ids)) == 2
    assert {:error, {:ambiguous, _}} = resolve("text_approval", :approve_once, c)
    assert {:ok, _, :deny} = resolve(c.pending.id, :deny, c)
    assert {:ok, ^second} = ExecApprovalStore.fetch_pending(second.id)
  end

  test "unauthorized caller, wrong account/chat and expiry preserve the request", c do
    assert {:error, :not_pending} =
             RemoteApproval.resolve_text(
               c.pending.id,
               :deny,
               "telegram",
               "default",
               fn _ -> false end,
               c.opts
             )

    assert {:error, :not_pending} =
             RemoteApproval.resolve_text(
               c.pending.id,
               :deny,
               "telegram",
               "other",
               fn _ -> true end,
               c.opts
             )

    assert {:error, :not_pending} =
             RemoteApproval.resolve_text(
               c.pending.id,
               :deny,
               "discord",
               "default",
               fn _ -> true end,
               c.opts
             )

    expired = %{c.pending | expires_at_ms: LemonCore.Clock.now_ms() - 1}
    :ok = ExecApprovalStore.put_pending(expired.id, expired)
    assert {:error, :not_pending} = resolve(expired.id, :approve_once, c)
    assert {:ok, ^expired} = ExecApprovalStore.fetch_pending(expired.id)
  end

  test "listed snapshot fingerprint detects replacement before fetch", c do
    replacement = %{c.pending | action: %{command: "changed"}}
    :ok = ExecApprovalStore.put_pending(replacement.id, replacement)
    opts = Keyword.put(c.opts, :list, fn -> {:ok, [{c.pending.id, c.pending}]} end)
    assert {:error, :rejected} = resolve(c.pending.id, :approve_once, %{c | opts: opts})
    assert {:ok, ^replacement} = ExecApprovalStore.fetch_pending(replacement.id)
  end

  test "atomic consume rejects replacement after fingerprint verification", c do
    replacement = %{c.pending | action: %{command: "changed"}}

    resolver = fn id, decision, opts ->
      assert opts[:expected_pending] == c.pending
      :ok = ExecApprovalStore.put_pending(id, replacement)
      ExecApprovals.resolve(id, decision, opts)
    end

    assert {:error, _} =
             resolve(c.pending.id, :approve_once, %{
               c
               | opts: Keyword.put(c.opts, :resolve, resolver)
             })

    assert {:ok, ^replacement} = ExecApprovalStore.fetch_pending(replacement.id)
  end

  test "list failure stays unavailable rather than claiming no pending approvals", c do
    assert {:error, :store_unavailable} =
             resolve("", :deny, %{
               c
               | opts: Keyword.put(c.opts, :list, fn -> {:error, :store_unavailable} end)
             })
  end

  test "edit renders the expired text for an owner-ended approval", c do
    assert :ok =
             RemoteApproval.edit(c.target, "55", :expired, %{reply_markup: %{}},
               enqueue: fn payload ->
                 send(self(), {:queued, payload})
                 {:ok, make_ref()}
               end
             )

    assert_receive {:queued, %{kind: :edit, content: %{message_id: "55", text: text}}}
    assert text == "Approval: Expired (the run ended)"
  end

  test "text command on an expired approval id reports expiry without resolving", c do
    expire(c.pending)
    opts = Keyword.put(c.opts, :list, fn -> {:ok, []} end)

    assert {:error, :run_ended} = resolve(c.pending.id, :approve_once, %{c | opts: opts})
    assert {:ok, nil} = ExecApprovalStore.fetch_pending(c.pending.id)

    assert {:error, :not_pending} = resolve("", :approve_once, %{c | opts: opts})
    assert {:error, :not_pending} = resolve("text_approval", :approve_once, %{c | opts: opts})

    unauthorized = %{c | target: %{c.target | account_id: "other"}}
    assert {:error, :not_pending} = resolve(c.pending.id, :approve_once, unauthorized)
  end

  test "non-expired terminal records stay not pending", c do
    terminal = %{resolution: %{approval_id: c.pending.id, outcome: :denied, decision: :deny}}
    :ok = ExecApprovalStore.delete_pending(c.pending.id)
    :ok = ExecApprovalStore.put_pending(c.pending.id, terminal)
    opts = Keyword.put(c.opts, :list, fn -> {:ok, []} end)
    assert {:error, :not_pending} = resolve(c.pending.id, :deny, %{c | opts: opts})
  end

  test "a timeout terminal record stays not pending and a time-expired pending stays expired",
       c do
    data = RemoteApproval.callback(c.pending, :approve_once)
    opts = Keyword.put(c.opts, :resolve, fn _, _, _ -> flunk("must not resolve") end)
    authorize = &(&1 == c.target)

    expired = %{c.pending | expires_at_ms: LemonCore.Clock.now_ms() - 1}
    :ok = ExecApprovalStore.delete_pending(c.pending.id)
    :ok = ExecApprovalStore.put_pending(c.pending.id, expired)

    assert {:error, :expired} =
             RemoteApproval.resolve(data, "telegram", "default", authorize, opts)

    timeout = %{
      resolution: %{
        approval_id: c.pending.id,
        session_key: c.pending.session_key,
        run_id: c.pending.run_id,
        decision: :timeout,
        outcome: :expired,
        resolved_at_ms: 1,
        pending_hash: "x"
      }
    }

    :ok = ExecApprovalStore.delete_pending(c.pending.id)
    :ok = ExecApprovalStore.put_pending(c.pending.id, timeout)

    assert {:error, :not_pending} =
             RemoteApproval.resolve(data, "telegram", "default", authorize, opts)

    list_opts = Keyword.put(opts, :list, fn -> {:ok, []} end)
    assert {:error, :not_pending} = resolve(c.pending.id, :approve_once, %{c | opts: list_opts})
  end

  test "button click on an expired approval returns the target and never resolves", c do
    expire(c.pending)
    data = RemoteApproval.callback(c.pending, :approve_once)
    opts = Keyword.put(c.opts, :resolve, fn _, _, _ -> flunk("must not resolve") end)

    assert {:error, {:run_ended, target}} =
             RemoteApproval.resolve(data, "telegram", "default", &(&1 == c.target), opts)

    assert target == c.target

    assert {:error, :rejected} =
             RemoteApproval.resolve(data, "telegram", "default", fn _ -> false end, opts)

    fetch_record = fn _ ->
      {:ok,
       %{
         resolution: %{
           outcome: :expired,
           decision: :expired,
           approval_id: "other",
           run_id: "r",
           session_key: "s"
         }
       }}
    end

    assert {:error, :not_pending} =
             RemoteApproval.resolve(
               data,
               "telegram",
               "default",
               &(&1 == c.target),
               Keyword.put(opts, :fetch_record, fetch_record)
             )
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

  defp resolve(selector, decision, c),
    do:
      RemoteApproval.resolve_text(
        selector,
        decision,
        "telegram",
        "default",
        fn target -> target == c.target end,
        c.opts
      )

  defp pending(id),
    do:
      ApprovalPending.new(%{
        id: id,
        run_id: "run_#{id}",
        session_key: "agent:test:main",
        tool: "bash",
        action: %{command: "pwd"},
        requested_at_ms: LemonCore.Clock.now_ms()
      })
end
