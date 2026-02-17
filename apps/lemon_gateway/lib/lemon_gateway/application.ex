defmodule LemonGateway.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        LemonGateway.Config,
        LemonGateway.Telegram.StartupNotifier,
        LemonGateway.EngineRegistry,
        LemonGateway.TransportRegistry,
        LemonGateway.CommandRegistry,
        LemonGateway.EngineLock,
        {Registry, keys: :unique, name: LemonGateway.RunRegistry},
        LemonGateway.ThreadRegistry,
        LemonGateway.Sms.Inbox,
        LemonGateway.Sms.WebhookServer,
        LemonGateway.RunSupervisor,
        LemonGateway.ThreadWorkerSupervisor,
        LemonGateway.Scheduler
        # lemon_channels is started explicitly by the top-level runtime app (or by
        # starting :lemon_control_plane / :lemon_channels directly). LemonGateway
        # does not attempt to orchestrate startup of sibling applications.
      ] ++ maybe_health_server_child()

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

  defp default_health_port do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      0
    else
      4042
    end
  end
end
