defmodule LemonGateway.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonGateway.Config,
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
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LemonGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
