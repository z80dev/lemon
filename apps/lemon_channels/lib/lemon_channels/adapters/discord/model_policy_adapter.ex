defmodule LemonChannels.Adapters.Discord.ModelPolicyAdapter do
  @moduledoc """
  Discord `/model` and `/thinking` preferences over `LemonCore.PolicyStore`
  (see `LemonChannels.Adapters.ModelPolicyShared`).
  """

  use LemonChannels.Adapters.ModelPolicyShared

  @impl true
  def channel_name, do: "discord"

  @impl true
  def build_route(account_id, channel_id, thread_id) do
    thread_str = if is_integer(thread_id), do: to_string(thread_id), else: nil
    {"discord", account_id, to_string(channel_id), thread_str}
  end

  @impl true
  def format_source_labels, do: %{topic: "thread default", chat: "channel default"}
end
