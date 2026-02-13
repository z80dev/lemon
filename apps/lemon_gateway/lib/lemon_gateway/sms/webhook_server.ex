defmodule LemonGateway.Sms.WebhookServer do
  @moduledoc false

  require Logger

  alias LemonGateway.Sms.Config

  def start_link(_opts \\ []) do
    if Config.webhook_enabled?() do
      port = Config.webhook_port()
      ip = Config.webhook_ip()

      Logger.info("Starting SMS webhook server on #{inspect(ip)}:#{port}")

      Bandit.start_link(
        plug: LemonGateway.Sms.WebhookRouter,
        port: port,
        ip: ip,
        scheme: :http
      )
    else
      :ignore
    end
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end
end

