defmodule LemonChannels.Adapters.Discord do
  @moduledoc """
  Discord channel adapter.
  """

  @behaviour LemonChannels.Plugin

  @impl true
  def id, do: "discord"

  @impl true
  def meta do
    %{
      label: "Discord",
      capabilities: %{
        edit_support: true,
        delete_support: true,
        chunk_limit: 2_000,
        rate_limit: 5,
        voice_support: false,
        image_support: true,
        file_support: true,
        reaction_support: false,
        thread_support: true
      },
      docs: "https://discord.com/developers/docs/intro"
    }
  end

  @impl true
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {LemonChannels.Adapters.Discord.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def normalize_inbound(raw) do
    LemonChannels.Adapters.Discord.Inbound.normalize(raw)
  end

  @impl true
  def deliver(payload) do
    LemonChannels.Adapters.Discord.Outbound.deliver(payload)
  end

  @impl true
  def gateway_methods, do: []
end
