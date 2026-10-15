defmodule LemonChannels.Adapters.Discord.UserPrompt do
  @moduledoc false
  alias LemonChannels.{RemoteApproval, UserPromptSurface}

  # The transport applies the same live guild/channel/binding guards as slash
  # commands before dispatching here. This boundary still binds user and thread.
  def handle(state, interaction) do
    channel = get(interaction, :channel)
    channel_id = RemoteApproval.integer(get(interaction, :channel_id))
    parent_id = RemoteApproval.integer(get(channel, :parent_id))
    thread? = is_map(get(channel, :thread_metadata)) or is_integer(parent_id)
    guild_id = RemoteApproval.integer(get(interaction, :guild_id))
    user = get(get(interaction, :member), :user) || get(interaction, :user)

    peer = %{
      kind: if(is_integer(guild_id), do: :group, else: :dm),
      id: string(if(thread?, do: parent_id || channel_id, else: channel_id)),
      thread_id: if(thread?, do: string(channel_id), else: nil)
    }

    UserPromptSurface.answer(
      get(get(interaction, :data), :custom_id),
      "discord",
      state.account_id,
      peer,
      string(get(user, :id))
    )
  end

  defp string(nil), do: nil
  defp string(id), do: to_string(id)
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_, _), do: nil
end
