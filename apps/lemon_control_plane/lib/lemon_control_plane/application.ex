defmodule LemonControlPlane.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Allow :lemon_router to call LemonCore.EventBridge without depending on
    # :lemon_control_plane at compile time.
    :ok = LemonCore.EventBridge.configure(LemonControlPlane.EventBridge)

    children = [
      # Method registry (ETS-backed for fast lookup)
      LemonControlPlane.Methods.Registry,
      # Presence tracker for connected clients
      LemonControlPlane.Presence,
      # Event bridge for bus -> WebSocket fanout
      LemonControlPlane.EventBridge,
      # Connection supervisor for WebSocket connections
      {DynamicSupervisor, strategy: :one_for_one, name: LemonControlPlane.ConnectionSupervisor},
      # Registry for connection processes
      {Registry, keys: :unique, name: LemonControlPlane.ConnectionRegistry},
      # HTTP/WebSocket server
      server_child_spec()
    ]

    opts = [strategy: :one_for_one, name: LemonControlPlane.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp server_child_spec do
    port = Application.get_env(:lemon_control_plane, :port, default_port())

    {Bandit,
     plug: LemonControlPlane.HTTP.Router,
     port: port,
     scheme: :http}
  end

  defp default_port do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      0
    else
      4040
    end
  end
end
