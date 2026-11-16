defmodule LemonControlPlane.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    with :ok <- LemonControlPlane.ListenerPolicy.validate() do
      start_supervisor()
    end
  end

  defp start_supervisor do
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
        # Registry owns connection membership; method tasks have a hard global bound.
        LemonControlPlane.Connections,
        Supervisor.child_spec(
          LemonCore.TaskSupervisor.child_spec(
            name: LemonControlPlane.MethodTaskSupervisor,
            max_children: LemonControlPlane.WS.Connection.global_method_limit()
          ),
          id: LemonControlPlane.MethodTaskSupervisor
        ),
        # Connection-owned machine terminals (no global terminal event fanout)
        LemonControlPlane.NodeShells,
        # Event bridge for bus -> WebSocket fanout
        LemonControlPlane.EventBridge,
        # WebSocket processes are owned by the HTTP server.
        # Durable A2A runs outlive an individual HTTP request or SSE client.
        LemonCore.TaskSupervisor.child_spec(name: LemonControlPlane.A2A.TaskSupervisor),
        LemonCore.TaskSupervisor.child_spec(name: LemonControlPlane.TaskSupervisor),
        # HTTP/WebSocket server
        server_child_spec(),
        {LemonControlPlane.NodeGateway,
         Application.get_env(:lemon_control_plane, :node_gateway,
           port: default_node_port(),
           ip: {127, 0, 0, 1}
         )}
      ] ++ a2a_children()

    opts = [strategy: :one_for_one, name: LemonControlPlane.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp server_child_spec do
    port = Application.get_env(:lemon_control_plane, :port, default_port())
    ip = Application.get_env(:lemon_control_plane, :ip, {127, 0, 0, 1})

    {Bandit, plug: LemonControlPlane.HTTP.Router, ip: ip, port: port, scheme: :http}
  end

  defp a2a_children do
    if LemonControlPlane.A2A.Config.enabled?() do
      config = LemonControlPlane.A2A.Config.current()

      [
        {LemonCore.RateLimiter,
         profile: :a2a,
         name: LemonControlPlane.A2A.RateLimiter,
         limit: fn -> LemonControlPlane.A2A.Config.current().rate_limit_per_minute end},
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

  defp default_node_port do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test, do: 0, else: 4044
  end

  defp default_port do
    if Code.ensure_loaded?(Mix) and Mix.env() == :test do
      0
    else
      4040
    end
  end
end
