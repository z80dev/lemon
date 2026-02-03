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
      LemonGateway.ThreadRegistry,
      LemonGateway.RunSupervisor,
      LemonGateway.ThreadWorkerSupervisor,
      LemonGateway.Scheduler,
      LemonGateway.Store,
      {LemonGateway.TransportSupervisor, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LemonGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
