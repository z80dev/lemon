defmodule LemonGateway.IngressSupervisor do
  @moduledoc """
  Supervisor for gateway-owned ingress children.

  Default `LemonGateway.Application` startup is empty; this supervisor
  starts only when `[gateway.ingress] enabled` is true. Each surface also has
  its own enable flag.

  These surfaces are gateway-owned **by design**, not pending migration. SMS is
  an OTP-code inbox exposed as agent tools with no reply path; webhook is a
  synchronous automation trigger that must answer in the request cycle that
  called it; voice holds a live bidirectional media session. None of the three
  fit `LemonChannels.Plugin`, whose `deliver/1` is fire-and-forget. Email was the
  one surface that moved to `lemon_channels`.

  See the "Transports" section of `apps/lemon_gateway/README.md` and decision D2
  in `docs/platform-split.md`.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      [
        LemonGateway.TransportRegistry,
        LemonGateway.Transports.Webhook.Idempotency,
        LemonGateway.TransportSupervisor,
        {Registry, keys: :unique, name: LemonGateway.Voice.CallRegistry},
        {Registry, keys: :unique, name: LemonGateway.Voice.DeepgramRegistry},
        {DynamicSupervisor,
         name: LemonGateway.Voice.CallSessionSupervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: LemonGateway.Voice.DeepgramSupervisor, strategy: :one_for_one}
      ] ++ sms_children() ++ maybe_voice_server_child()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The SMS inbox (and with it the agent SMS tools) exists only when the SMS
  # webhook is enabled and has an auth token to verify Twilio signatures.
  defp sms_children do
    if LemonGateway.Sms.Config.usable?() do
      [LemonGateway.Sms.Inbox, LemonGateway.Sms.WebhookServer]
    else
      []
    end
  end

  defp maybe_voice_server_child do
    if LemonGateway.Voice.Config.enabled?() do
      [voice_server_child_spec()]
    else
      []
    end
  end

  # Binds loopback unless told otherwise, matching the health server and
  # `LemonChannels.InboundHttp`. This listener used to bind every interface
  # because it passed no `:ip` at all; a deployment that fronts it with a tunnel
  # or reverse proxy on another host needs to say so explicitly now:
  #
  #     config :lemon_gateway, :voice_ip, {0, 0, 0, 0}
  defp voice_server_child_spec do
    port = LemonGateway.Voice.Config.websocket_port()
    ip = Application.get_env(:lemon_gateway, :voice_ip, :loopback)

    %{
      id: LemonGateway.Voice.Server,
      start:
        {Bandit, :start_link,
         [[plug: LemonGateway.Voice.WebhookRouter, ip: ip, port: port, scheme: :http]]},
      type: :supervisor
    }
  end
end
