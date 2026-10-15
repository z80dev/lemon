defmodule LemonChannels.Adapters.Discord.ApprovalTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Approval
  alias LemonChannels.Adapters.Discord.Transport
  alias LemonChannels.Discord.KnownTargetStore
  alias LemonChannels.{OutboundPayload, RemoteApproval, Supervision}
  alias LemonCore.Events.ApprovalPending
  alias LemonCore.ExecApprovalStore

  setup do
    id = LemonCore.Id.approval_id()

    target = %{
      channel_id: "discord",
      account_id: "default",
      peer: %{kind: :group, id: "123", thread_id: "456"}
    }

    pending =
      ApprovalPending.new(%{
        id: id,
        run_id: "run_#{id}",
        session_key: "agent:test:child:#{id}",
        tool: "bash",
        action: %{command: "pwd"}
      })

    :ok = Supervision.bind_run(pending.run_id, pending.session_key, target)
    :ok = ExecApprovalStore.put_pending(id, pending)
    key = {"default", 123, 456}
    previous = KnownTargetStore.get(key)
    :ok = KnownTargetStore.put(key, %{guild_id: 789})

    on_exit(fn ->
      ExecApprovalStore.delete_pending(id)

      if previous,
        do: KnownTargetStore.put(key, previous),
        else: LemonCore.Store.delete(:discord_known_targets, key)
    end)

    state = %{
      account_id: "default",
      allowed_channel_ids: MapSet.new([456]),
      allowed_guild_ids: MapSet.new([789]),
      deny_unbound_channels: false
    }

    interaction = %{
      channel_id: "456",
      guild_id: "789",
      channel: %{parent_id: "123"},
      message: %{id: "999"},
      data: %{custom_id: RemoteApproval.callback(pending, :deny)}
    }

    opts = [
      enqueue: fn payload ->
        send(self(), {:queued, payload})
        {:ok, make_ref()}
      end
    ]

    %{pending: pending, target: target, state: state, interaction: interaction, opts: opts}
  end

  test "text commands use the button location authorization without a component message", c do
    interaction = Map.delete(c.interaction, :message)

    context = %{
      surface: "discord",
      account_id: "default",
      approval_authorize: Approval.text_authorizer(c.state, interaction)
    }

    wrong = %{
      context
      | approval_authorize: Approval.text_authorizer(c.state, %{interaction | channel_id: "999"})
    }

    assert {:error, message} =
             LemonChannels.PortableCommand.handle("approve", c.pending.id, wrong)

    assert message =~ "No matching pending"

    assert {:ok, "Approval: Approved (once)"} =
             LemonChannels.PortableCommand.handle("approve", c.pending.id, context)

    assert {:error, message} = LemonChannels.PortableCommand.handle("deny", c.pending.id, context)
    assert message =~ "already been resolved"
  end

  test "text deny accepts a unique prefix", c do
    context = %{
      surface: "discord",
      account_id: "default",
      approval_authorize: Approval.text_authorizer(c.state, Map.delete(c.interaction, :message))
    }

    assert {:ok, "Approval: Denied"} =
             LemonChannels.PortableCommand.handle(
               "deny",
               String.slice(c.pending.id, 0..-2//1),
               context
             )
  end

  test "request uses matching account, exact target and once/deny Outbox components", c do
    assert :ok = Approval.send(c.state, %{approval_id: c.pending.id, pending: c.pending}, c.opts)

    assert_receive {:queued,
                    %OutboundPayload{
                      kind: :text,
                      account_id: "default",
                      peer: peer,
                      meta: %{components: [row]}
                    }}

    assert peer == c.target.peer
    assert length(row.components) == 2

    assert Enum.map(row.components, & &1.custom_id) == [
             RemoteApproval.callback(c.pending, :approve_once),
             RemoteApproval.callback(c.pending, :deny)
           ]

    for state <- [
          %{c.state | account_id: "foreign"},
          %{c.state | allowed_channel_ids: MapSet.new([123])},
          %{c.state | allowed_guild_ids: MapSet.new([888])},
          %{c.state | deny_unbound_channels: true}
        ] do
      assert {:error, _} =
               Approval.send(state, %{approval_id: c.pending.id, pending: c.pending}, c.opts)

      refute_receive {:queued, _}
    end
  end

  test "foreign channel/thread/parent/account and denied guild never consume or edit", c do
    interactions = [
      %{c.interaction | channel_id: "457"},
      %{c.interaction | channel: %{parent_id: "124"}},
      %{c.interaction | channel: %{}},
      %{c.interaction | guild_id: "790"},
      %{c.interaction | channel_id: "456garbage"},
      %{c.interaction | message: %{id: "999garbage"}},
      %{c.interaction | data: %{custom_id: c.pending.id <> "|once"}},
      %{c.interaction | data: %{custom_id: nil}}
    ]

    for interaction <- interactions do
      assert {:error, _} = Approval.handle(c.state, interaction, c.opts)
      assert {:ok, pending} = ExecApprovalStore.fetch_pending(c.pending.id)
      assert pending == c.pending
      refute_receive {:queued, _}
    end

    assert {:error, _} =
             Approval.handle(%{c.state | account_id: "foreign"}, c.interaction, c.opts)

    refute_receive {:queued, _}
  end

  test "deny resolves the real pending record and queues only its source edit; replay rejected",
       c do
    assert :ok = Approval.handle(c.state, c.interaction, c.opts)

    assert_receive {:queued,
                    %OutboundPayload{
                      kind: :edit,
                      peer: peer,
                      content: %{message_id: "999", text: "Approval: Denied"},
                      meta: %{components: []}
                    }}

    assert peer == c.target.peer
    assert {:ok, nil} = ExecApprovalStore.fetch_pending(c.pending.id)
    assert {:error, :not_pending} = Approval.handle(c.state, c.interaction, c.opts)
    refute_receive {:queued, _}
  end

  test "stale, expired, missing and unavailable records never edit", c do
    for replacement <- [
          %{c.pending | action: %{command: "changed"}},
          %{c.pending | expires_at_ms: LemonCore.Clock.now_ms() - 1}
        ] do
      :ok = ExecApprovalStore.delete_pending(c.pending.id)
      :ok = ExecApprovalStore.put_pending(c.pending.id, replacement)
      assert {:error, _} = Approval.handle(c.state, c.interaction, c.opts)
      assert {:ok, ^replacement} = ExecApprovalStore.fetch_pending(c.pending.id)
      refute_receive {:queued, _}
    end

    :ok = ExecApprovalStore.delete_pending(c.pending.id)
    assert {:error, :not_pending} = Approval.handle(c.state, c.interaction, c.opts)
    :ok = ExecApprovalStore.put_pending(c.pending.id, c.pending)

    for failure <- [
          [fetch: fn _ -> {:error, :store_unavailable} end],
          [resolve: fn _, _, _ -> {:error, :store_unavailable} end],
          [resolve: fn _, _, _ -> {:error, :expired} end],
          [resolve: fn _, _, _ -> {:error, :mismatch} end]
        ] do
      assert {:error, _} = Approval.handle(c.state, c.interaction, Keyword.merge(c.opts, failure))
      refute_receive {:queued, _}
      assert {:ok, pending} = ExecApprovalStore.fetch_pending(c.pending.id)
      assert pending == c.pending
    end
  end

  test "transport rejects a foreign component without claiming success", c do
    parent = self()
    previous = Application.get_env(:lemon_channels, :discord_interaction_responder)

    Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction,
                                                                            payload ->
      send(parent, {:response, interaction, payload})
      :ok
    end)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:lemon_channels, :discord_interaction_responder),
        else: Application.put_env(:lemon_channels, :discord_interaction_responder, previous)
    end)

    interaction = c.interaction |> Map.put(:type, 3) |> Map.put(:channel_id, "999")

    assert {:noreply, state} =
             Transport.handle_info(
               {:discord_event, {:INTERACTION_CREATE, interaction, nil}},
               c.state
             )

    assert state == c.state
    assert_receive {:response, ^interaction, %{type: 4, data: %{content: text, flags: 64}}}

    assert text ==
             "This approval cannot be used here; nothing changed. Open the approval in its original conversation."

    assert {:ok, pending} = ExecApprovalStore.fetch_pending(c.pending.id)
    assert pending == c.pending
  end
end
