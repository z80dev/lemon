defmodule LemonChannels.Adapters.WhatsApp.ModelPolicyAdapter do
  @moduledoc """
  WhatsApp `/model` and `/thinking` preferences over `LemonCore.PolicyStore`
  (see `LemonChannels.Adapters.ModelPolicyShared`).
  """

  use LemonChannels.Adapters.ModelPolicyShared

  @impl true
  def channel_name, do: "whatsapp"

  @impl true
  def build_route(account_id, chat_id, thread_id) do
    thread_str = if is_binary(thread_id) and thread_id != "", do: thread_id, else: nil
    {"whatsapp", account_id, chat_id, thread_str}
  end

  @impl true
  def format_source_labels, do: %{topic: "topic default", chat: "chat default"}
end
