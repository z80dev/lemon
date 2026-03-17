defmodule LemonChannels.Adapters.WhatsApp.Supervisor do
  @moduledoc """
  Supervisor for WhatsApp adapter processes.

  Starts both the inbound transport and manages outbound delivery.
  Only starts children if credentials_path is configured.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Allow running lemon_channels without any WhatsApp credentials configured.
    base = LemonChannels.GatewayConfig.get(:whatsapp, %{}) || %{}

    config =
      base
      |> merge_config(Keyword.get(opts, :config))

    credentials_path = config[:credentials_path] || config["credentials_path"]

    children =
      if is_binary(credentials_path) and credentials_path != "" do
        [
          {Task.Supervisor, name: LemonChannels.Adapters.WhatsApp.AsyncSupervisor},
          {LemonChannels.Adapters.WhatsApp.Transport, [config: config]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp merge_config(base, opts), do: LemonCore.MapHelpers.merge_config(base, opts)
end
