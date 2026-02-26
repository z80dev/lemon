defmodule LemonChannels.Adapters.Telegram do
  @moduledoc """
  Telegram channel adapter.
  """

  @behaviour LemonChannels.Plugin

  @impl true
  def id, do: "telegram"

  @impl true
  def meta do
    %{
      label: "Telegram",
      capabilities: %{
        edit_support: true,
        delete_support: true,
        chunk_limit: 4096,
        rate_limit: 30,
        voice_support: true,
        image_support: true,
        file_support: true,
        reaction_support: true,
        thread_support: true
      },
      docs: "https://core.telegram.org/bots/api"
    }
  end

  @impl true
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {LemonChannels.Adapters.Telegram.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def normalize_inbound(raw) do
    LemonChannels.Adapters.Telegram.Inbound.normalize(raw)
  end

  @impl true
  def deliver(payload) do
    LemonChannels.Adapters.Telegram.Outbound.deliver(payload)
  end

  @impl true
  def gateway_methods do
    # Telegram-specific control plane methods could be added here
    []
  end
end
