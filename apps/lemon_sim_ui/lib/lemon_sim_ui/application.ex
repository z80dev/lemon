defmodule LemonSimUi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonSimUi.Telemetry,
      {DynamicSupervisor, name: LemonSimUi.SimRunnerSupervisor, strategy: :one_for_one},
      LemonSimUi.SimManager,
      LemonSimUi.Endpoint
    ]

    opts = [strategy: :one_for_one, name: LemonSimUi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    LemonSimUi.Endpoint.config_change(changed, removed)
    :ok
  end
end
