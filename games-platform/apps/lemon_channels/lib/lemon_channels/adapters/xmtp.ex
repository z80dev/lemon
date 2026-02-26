defmodule LemonChannels.Adapters.Xmtp do
  @moduledoc """
  XMTP channel adapter.
  """

  @behaviour LemonChannels.Plugin

  @impl true
  def id, do: "xmtp"

  @impl true
  def meta do
    %{
      label: "XMTP",
      capabilities: %{
        edit_support: false,
        delete_support: false,
        chunk_limit: 2_000,
        voice_support: false,
        image_support: false,
        file_support: false,
        reaction_support: false,
        thread_support: true
      },
      docs: "https://xmtp.org"
    }
  end

  @impl true
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {LemonChannels.Adapters.Xmtp.Transport, :start_link, [opts]},
      type: :worker
    }
  end

  @impl true
  def normalize_inbound(raw) do
    LemonChannels.Adapters.Xmtp.Transport.normalize_inbound_message(raw)
  end

  @impl true
  def deliver(payload) do
    LemonChannels.Adapters.Xmtp.Transport.deliver(payload)
  end

  @impl true
  def gateway_methods, do: []

  @doc """
  Returns true when XMTP is enabled in gateway config.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    LemonChannels.Adapters.Xmtp.Transport.enabled?()
  end
end
