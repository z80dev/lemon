defmodule LemonWeb.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    endpoint = Application.get_env(:lemon_web, LemonWeb.Endpoint, [])
    ip = endpoint |> Keyword.get(:http, []) |> Keyword.get(:ip, {127, 0, 0, 1})

    with :ok <- LemonControlPlane.ListenerPolicy.validate_operator_bind(ip, "LemonWeb") do
      start_supervisor()
    end
  end

  defp start_supervisor do
    # Global run start/stop feed for shell notifications (idempotent).
    LemonWeb.ShellLive.RunEvents.attach()

    children = [
      LemonWeb.Telemetry,
      LemonWeb.LoginThrottle,
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
