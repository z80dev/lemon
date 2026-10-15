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
