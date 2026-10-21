defmodule LemonControlPlane.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Allow :lemon_router to call LemonCore.EventBridge without depending on
    # :lemon_control_plane at compile time.
    :ok = LemonCore.EventBridge.configure(LemonControlPlane.EventBridge)

    children =
      [
        # Bounded in-memory log tail backing `logs.tail`
        LemonControlPlane.LogRing,
        # Method registry (ETS-backed for fast lookup)
        LemonControlPlane.Methods.Registry,
        LemonControlPlane.Lifecycle,
        # Presence tracker for connected clients
        LemonControlPlane.Presence,
        # Connection-owned machine terminals (no global terminal event fanout)
        LemonControlPlane.NodeShells,
        # Event bridge for bus -> WebSocket fanout
        LemonControlPlane.EventBridge,
        # Connection supervisor for WebSocket connections
        {DynamicSupervisor, strategy: :one_for_one, name: LemonControlPlane.ConnectionSupervisor},
        # Registry for connection processes
        {Registry, keys: :unique, name: LemonControlPlane.ConnectionRegistry},
        # Durable A2A runs outlive an individual HTTP request or SSE client.
        {Task.Supervisor, name: LemonControlPlane.A2A.TaskSupervisor},
        # HTTP/WebSocket server
        server_child_spec()
      ] ++ a2a_children()

    opts = [strategy: :one_for_one, name: LemonControlPlane.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp server_child_spec do
    port = Application.get_env(:lemon_control_plane, :port, default_port())
    ip = Application.get_env(:lemon_control_plane, :ip, :any)

    {Bandit, plug: LemonControlPlane.HTTP.Router, ip: ip, port: port, scheme: :http}
  end

  defp a2a_children do
    if LemonControlPlane.A2A.Config.enabled?() do
      config = LemonControlPlane.A2A.Config.current()

      [
        LemonControlPlane.A2A.RateLimiter,
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.A2A.Router,
           ip: LemonControlPlane.A2A.Config.bind_ip(config),
           port: config.port,
           scheme: :http},
          id: LemonControlPlane.A2A.Server
        )
      ]
    else
      []
    end
  end

  defp default_port do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      0
    else
      4040
    end
  end
end
