defmodule LemonGateway.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    base_children = [
      LemonGateway.Config,
      LemonGateway.EngineRegistry,
      LemonGateway.TransportRegistry,
      LemonGateway.CommandRegistry,
      LemonGateway.EngineLock,
      LemonGateway.ThreadRegistry,
      LemonGateway.RunSupervisor,
      LemonGateway.ThreadWorkerSupervisor,
      LemonGateway.Scheduler,
      LemonGateway.Store
    ]
    
    # Start the Cowboy web server
    web_children = [
      {Plug.Cowboy, scheme: :http, plug: LemonGateway.Web.Router, options: [port: 3939, dispatch: dispatch()]}
    ]

    # Only start legacy TransportSupervisor if lemon_channels is NOT active
    # to avoid duplicate ingestion from both systems
    children =
      if lemon_channels_active?() do
        base_children ++ web_children
      else
        base_children ++ [{LemonGateway.TransportSupervisor, []}] ++ web_children
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LemonGateway.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp dispatch do
    [
      {:_, [
        {"/ws", LemonGateway.Web.SocketHandler, []},
        {:_, Plug.Cowboy.Handler, {LemonGateway.Web.Router, []}}
      ]}
    ]
  end

  # Check if lemon_channels application is running and has adapters enabled
  defp lemon_channels_active? do
    # Check if the lemon_channels application is started
    case Application.ensure_started(:lemon_channels) do
      :ok -> true
      {:error, {:already_started, :lemon_channels}} -> true
      _ ->
        # Also check if it's in the started applications
        :lemon_channels in Enum.map(Application.started_applications(), fn {app, _, _} -> app end)
    end
  rescue
    # If lemon_channels doesn't exist, fall back to legacy
    _ -> false
  end
end
