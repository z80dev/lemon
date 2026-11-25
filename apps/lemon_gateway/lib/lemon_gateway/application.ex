defmodule LemonGateway.Application do
  @moduledoc """
  OTP application for LemonGateway, an opt-in ingress satellite.

  Execution is not here: `LemonRouter.RunProcess` owns every run, its permit
  and its executor. The gateway hosts only its own ingress (webhook, SMS,
  voice), which starts when `:gateway_ingress_enabled` is set for
  `:lemon_gateway` (see `LemonGateway.IngressSupervisor`), together with the
  voice task supervisor and the health server. Disabled, it starts an empty
  supervisor and opens no listener. Gateway settings are read live from
  `LemonCore.GatewayConfig`; there is no config process.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Channels and the control plane ask core for transport/config facts rather
    # than reaching into this app; register ourselves as the implementation.
    LemonCore.EngineInfoBridge.configure(
      transport_registry: LemonGateway.TransportRegistry,
      sms_inbox: LemonGateway.Sms.Inbox
    )

    children =
      if gateway_ingress_enabled?() do
        # Bounded owner for voice-call LLM/TTS operations (#588).
        [{LemonCore.TaskSupervisor, name: LemonGateway.TaskSupervisor}] ++
          maybe_health_server_child() ++ [LemonGateway.IngressSupervisor]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: LemonGateway.Supervisor)
  end

  defp maybe_health_server_child do
    if health_enabled?() do
      [health_server_child_spec()]
    else
      []
    end
  end

  defp health_server_child_spec do
    port = Application.get_env(:lemon_gateway, :health_port, 4042)
    ip = Application.get_env(:lemon_gateway, :health_ip, :loopback)

    %{
      id: LemonGateway.Health.Server,
      start:
        {Bandit, :start_link,
         [[plug: LemonGateway.Health.Router, ip: ip, port: port, scheme: :http]]},
      type: :supervisor
    }
  end

  defp health_enabled? do
    Application.get_env(:lemon_gateway, :health_enabled, true)
  end

  defp gateway_ingress_enabled? do
    Application.get_env(:lemon_gateway, :gateway_ingress_enabled, false)
  end
end
