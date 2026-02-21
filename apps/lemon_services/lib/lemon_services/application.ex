defmodule LemonServices.Application do
  @moduledoc """
  OTP Application for LemonServices.

  Starts the supervision tree including:
  - Registry for service lookup
  - PubSub for event broadcasting
  - Runtime supervisor for service processes
  - Config loader for static service definitions
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for service process lookup (unique keys by service ID)
      {Registry, keys: :unique, name: LemonServices.Registry},

      # PubSub for broadcasting service events
      {Phoenix.PubSub, name: LemonServices.PubSub},

      # DynamicSupervisor for runtime service supervisors
      {DynamicSupervisor,
       strategy: :one_for_one, name: LemonServices.Runtime.Supervisor},

      # Main supervisor
      LemonServices.Supervisor
    ]

    opts = [strategy: :one_for_one, name: LemonServices.Application]
    Supervisor.start_link(children, opts)
  end
end
