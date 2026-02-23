defmodule LemonIngestion.Application do
  @moduledoc """
  OTP Application for LemonIngestion.

  Starts the supervision tree including:
  - Subscription Registry (ETS-based)
  - Event Router
  - Adapter Supervisor (for pollers/streamers)
  - HTTP Endpoint (optional, for receiving webhooks)
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Task supervisor for async delivery
      {Task.Supervisor, name: LemonIngestion.TaskSupervisor},

      # Registry for subscriptions (who wants what events)
      LemonIngestion.Registry,

      # Event router (matches events to subscriptions and delivers)
      LemonIngestion.Router,

      # Adapter supervisor (manages pollers/streamers for each source)
      LemonIngestion.Adapters.Supervisor,

      # Optional HTTP endpoint for receiving external webhooks
      maybe_http_server()
    ]
    |> List.flatten()

    opts = [strategy: :one_for_one, name: LemonIngestion.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_http_server do
    if Application.get_env(:lemon_ingestion, :http_enabled, true) do
      port = Application.get_env(:lemon_ingestion, :http_port, 4048)

      {
        Bandit,
        plug: LemonIngestion.HTTP.Router,
        port: port,
        scheme: :http
      }
    else
      []
    end
  end
end
