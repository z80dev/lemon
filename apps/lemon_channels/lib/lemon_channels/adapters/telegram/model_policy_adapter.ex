defmodule LemonChannels.Adapters.Telegram.ModelPolicyAdapter do
  @moduledoc """
  Telegram `/model` and `/thinking` preferences over `LemonCore.PolicyStore`
  (see `LemonChannels.Adapters.ModelPolicyShared`).
  """

  use LemonChannels.Adapters.ModelPolicyShared

  @impl true
  def channel_name, do: "telegram"

  @impl true
  def build_route(account_id, chat_id, thread_id) do
    thread_str = if is_integer(thread_id), do: to_string(thread_id), else: nil
    {"telegram", account_id, to_string(chat_id), thread_str}
  end

  @impl true
  def format_source_labels, do: %{topic: "topic default", chat: "chat default"}
end
