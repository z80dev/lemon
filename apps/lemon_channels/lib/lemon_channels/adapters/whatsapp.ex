defmodule LemonChannels.Adapters.WhatsApp do
  @moduledoc "WhatsApp channel adapter."
  @behaviour LemonChannels.Plugin

  @impl true
  def id, do: "whatsapp"

  @impl true
  def meta do
    %{
      label: "WhatsApp",
      capabilities: %{
        edit_support: false,
        delete_support: false,
        chunk_limit: 4096,
        voice_support: true,
        image_support: true,
        file_support: true,
        reaction_support: true,
        thread_support: true
      },
      docs: nil
    }
  end

  @impl true
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {LemonChannels.Adapters.WhatsApp.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def normalize_inbound(raw), do: LemonChannels.Adapters.WhatsApp.Inbound.normalize(raw)

  @impl true
  def deliver(payload), do: LemonChannels.Adapters.WhatsApp.Outbound.deliver(payload)

  @impl true
  def gateway_methods, do: []
end
