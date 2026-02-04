defmodule LemonChannels.Adapters.Telegram.Supervisor do
  @moduledoc """
  Supervisor for Telegram adapter processes.

  Starts both the inbound transport (polling) and manages outbound delivery.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Check if Telegram is configured
    config = Application.get_env(:lemon_gateway, :telegram, %{})
    token = config[:bot_token] || config["bot_token"]

    children =
      if is_binary(token) and token != "" do
        [
          # Start the inbound transport (polling)
          {LemonChannels.Adapters.Telegram.Transport, [config: config]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
