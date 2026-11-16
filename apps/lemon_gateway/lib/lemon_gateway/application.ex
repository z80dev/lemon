defmodule LemonGateway.Application do
  @moduledoc """
  OTP application for LemonGateway.

  Starts the execution supervision tree: configuration, the singleton executor,
  execution permits, run supervisors, and the health check server.

  Gateway-owned ingress (transport, SMS, voice) is off by default and
  starts only when `:gateway_ingress_enabled` is set for `:lemon_gateway`. See
  `LemonGateway.IngressSupervisor`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    with :ok <- validate_configured_executor() do
      children =
        [
          LemonGateway.Config,
          {Registry, keys: :unique, name: LemonGateway.RunRegistry},
          LemonGateway.Slots,
          LemonGateway.RunSupervisor,
          {Task.Supervisor, name: LemonGateway.TaskSupervisor}
          # lemon_channels is started explicitly by the top-level runtime app (or by
          # starting :lemon_control_plane / lemon_channels directly). LemonGateway
          # does not attempt to orchestrate startup of sibling applications.
        ] ++ maybe_health_server_child() ++ maybe_gateway_ingress_children()

      # Channels and the control plane ask core for transport/config facts rather
      # than reaching into this app; register ourselves as the implementation.
      LemonCore.EngineInfoBridge.configure(
        transport_registry: LemonGateway.TransportRegistry,
        gateway_config: LemonGateway.Config
      )

      # Gateway owns the progress-message index; the store does not know it
      # exists, so ask it to mirror the table into its read cache.
      LemonCore.Store.register_cached_table(LemonGateway.ProgressStore.table())

      # A lost permit authority or registry must stop its Runs before admitting
      # new work; otherwise a restarted counter could oversubscribe execution.
      opts = [strategy: :rest_for_one, name: LemonGateway.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end

  defp validate_configured_executor, do: LemonGateway.Executor.validate_configured()

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

  defp maybe_gateway_ingress_children do
    if gateway_ingress_enabled?() do
      [LemonGateway.IngressSupervisor]
    else
      []
    end
  end

  defp gateway_ingress_enabled? do
    Application.get_env(:lemon_gateway, :gateway_ingress_enabled, false)
  end
end
