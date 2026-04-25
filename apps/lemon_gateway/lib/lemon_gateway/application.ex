defmodule LemonGateway.Application do
  @moduledoc """
  OTP application for LemonGateway.

  Starts the execution supervision tree: configuration, engine registries,
  schedulers, run supervisors, and the health check server.

  Legacy gateway ingress is transitional and only starts when
  `:legacy_ingress_enabled` is set for `:lemon_gateway`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        LemonGateway.Config,
        LemonGateway.EngineRegistry,
        LemonGateway.EngineLock,
        {Registry, keys: :unique, name: LemonGateway.RunRegistry},
        LemonGateway.ThreadRegistry,
        LemonGateway.RunSupervisor,
        LemonGateway.ThreadWorkerSupervisor,
        {Task.Supervisor, name: LemonGateway.TaskSupervisor},
        LemonGateway.Scheduler
        # lemon_channels is started explicitly by the top-level runtime app (or by
        # starting :lemon_control_plane / lemon_channels directly). LemonGateway
        # does not attempt to orchestrate startup of sibling applications.
      ] ++ maybe_health_server_child() ++ maybe_legacy_ingress_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LemonGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_health_server_child do
    if health_enabled?() do
      [health_server_child_spec()]
    else
      []
    end
  end

  defp health_server_child_spec do
    port = Application.get_env(:lemon_gateway, :health_port, default_health_port())
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

  defp maybe_legacy_ingress_children do
    if legacy_ingress_enabled?() do
      [LemonGateway.LegacyIngressSupervisor]
    else
      []
    end
  end

  defp legacy_ingress_enabled? do
    Application.get_env(:lemon_gateway, :legacy_ingress_enabled, false)
  end

  defp default_health_port do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      0
    else
      4042
    end
  end
end
