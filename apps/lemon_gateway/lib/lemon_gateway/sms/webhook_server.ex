defmodule LemonGateway.Sms.WebhookServer do
  @moduledoc """
  Starts a Bandit HTTP server to host the SMS webhook endpoint.

  Reads the port and bind IP from `LemonGateway.Sms.Config` and serves
  `LemonGateway.Sms.WebhookRouter`. The server starts only when the webhook is
  enabled and a Twilio auth token is configured; without a token it logs an
  error and does not listen, because no request could pass signature checks.
  """

  require Logger

  alias LemonGateway.Sms.Config

  def start_link(_opts \\ []) do
    cond do
      not Config.webhook_enabled?() ->
        :ignore

      is_nil(Config.auth_token()) ->
        Logger.error(
          "SMS webhook is enabled but no Twilio auth token is configured " <>
            "(TWILIO_AUTH_TOKEN or [gateway.sms] auth_token_secret); not starting the listener"
        )

        :ignore

      true ->
        port = Config.webhook_port()
        ip = Config.webhook_ip()

        Logger.info("Starting SMS webhook server on #{inspect(ip)}:#{port}")

        with {:ok, pid} <-
               Bandit.start_link(
                 plug: LemonGateway.Sms.WebhookRouter,
                 port: port,
                 ip: ip,
                 scheme: :http
               ) do
          # Registered so tool injection can confirm the listener is live.
          true = Process.register(pid, __MODULE__)
          {:ok, pid}
        end
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
