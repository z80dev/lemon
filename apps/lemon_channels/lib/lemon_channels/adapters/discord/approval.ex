defmodule LemonChannels.Adapters.Discord.Approval do
  @moduledoc "Account- and conversation-bound Discord approval controls, delivered through Outbox."

  alias LemonChannels.Adapters.Discord.StatusRenderer
  alias LemonChannels.BindingResolver
  alias LemonChannels.Discord.KnownTargetStore
  alias LemonChannels.RemoteApproval
  alias LemonCore.ChatScope

  def send(state, payload, opts \\ []) do
    with {:ok, pending, target} <-
           RemoteApproval.request(
             payload,
             "discord",
             state.account_id,
             &authorized_target?(state, &1),
             opts
           ) do
      components = [
        StatusRenderer.action_row([
          StatusRenderer.button("Approve once", RemoteApproval.callback(pending, :approve_once),
            style: :success
          ),
          StatusRenderer.button("Deny", RemoteApproval.callback(pending, :deny), style: :danger)
        ])
      ]

      RemoteApproval.enqueue(
        target,
        "Approval requested: #{pending.tool}\nAction: #{RemoteApproval.action_text(pending.action)}",
        %{components: components},
        Keyword.put(
          opts,
          :idempotency_key,
          "approval:discord:#{RemoteApproval.callback(pending, :approve_once)}"
        )
      )
    end
  end

  def handle(state, interaction, opts \\ []) do
    data = get(get(interaction, :data), :custom_id)

    result =
      RemoteApproval.resolve(
        data,
        "discord",
        Map.get(state, :account_id),
        fn target ->
          matches?(interaction, target) and
            authorized?(state, target, get(interaction, :guild_id))
        end,
        opts
      )

    case result do
      {:ok, target, decision} ->
        _ =
          RemoteApproval.edit(
            target,
            get(get(interaction, :message), :id),
            decision,
            %{components: []},
            opts
          )

        :ok

      {:error, _} = error ->
        error
    end
  end

  def text_authorizer(state, interaction) do
    fn target ->
      matches?(Map.put(interaction, :message, %{id: "1"}), target) and
        authorized?(state, target, get(interaction, :guild_id))
    end
  end

  defp matches?(interaction, target) do
    peer = target.peer
    channel = get(interaction, :channel)
    channel_id = RemoteApproval.integer(get(interaction, :channel_id))
    parent_id = RemoteApproval.integer(get(channel, :parent_id))
    thread? = is_map(get(channel, :thread_metadata)) or is_integer(parent_id)
    message_id = RemoteApproval.integer(get(get(interaction, :message), :id))
    guild_id = RemoteApproval.integer(get(interaction, :guild_id))
    kind = if is_integer(guild_id), do: :group, else: :dm

    is_integer(message_id) and message_id > 0 and kind == peer.kind and
      if is_nil(peer.thread_id) do
        not thread? and channel_id == RemoteApproval.integer(peer.id)
      else
        thread? and channel_id == RemoteApproval.integer(peer.thread_id) and
          (peer.id == peer.thread_id or parent_id == RemoteApproval.integer(peer.id))
      end
  end

  defp authorized_target?(state, target) do
    peer = target.peer

    key =
      {target.account_id, RemoteApproval.integer(peer.id), RemoteApproval.integer(peer.thread_id)}

    metadata = KnownTargetStore.get(key)
    authorized?(state, target, get(metadata, :guild_id))
  end

  defp authorized?(state, target, guild) do
    peer = target.peer
    channel_id = RemoteApproval.integer(peer.thread_id || peer.id)
    guild_id = RemoteApproval.integer(guild)

    allowed?(Map.get(state, :allowed_guild_ids), guild_id) and
      allowed?(Map.get(state, :allowed_channel_ids), channel_id) and
      (Map.get(state, :deny_unbound_channels, false) != true or peer.kind == :dm or
         not is_nil(
           BindingResolver.resolve_binding(%ChatScope{
             transport: :discord,
             chat_id: RemoteApproval.integer(peer.id),
             topic_id: RemoteApproval.integer(peer.thread_id)
           })
         ))
  end

  defp allowed?(nil, _id), do: true
  defp allowed?(%MapSet{} = allowed, id), do: is_integer(id) and MapSet.member?(allowed, id)
  defp allowed?(_, _), do: false
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_, _), do: nil
end
