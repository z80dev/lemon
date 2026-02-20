defmodule LemonWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonWeb.Telemetry,
      LemonWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: LemonWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    LemonWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
