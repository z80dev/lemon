defmodule LemonGateway.Application do
  @moduledoc """
  OTP application for LemonGateway, an opt-in ingress satellite.

  `LemonRouter.RunProcess` owns execution, permits and the executor. Gateway
  starts its webhook, SMS and voice ingress only when `[gateway.ingress] enabled`
  is true, along with the voice task supervisor and optional health listener.
  Otherwise it starts an empty supervisor and opens no listener. Settings are
  read live through `LemonCore.GatewayConfig`.
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
    ingress = LemonCore.GatewayConfig.get(:ingress)
    LemonCore.GatewayConfig.fetch(ingress, :enabled, false) == true
  end
end
