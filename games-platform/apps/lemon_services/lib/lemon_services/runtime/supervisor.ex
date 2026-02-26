defmodule LemonServices.Runtime.Supervisor do
  @moduledoc """
  Per-service supervisor.

  Each running service gets its own supervisor with:
  - Server (main GenServer)
  - PortManager (port lifecycle)
  - HealthChecker (health checks)
  - LogBuffer (log storage)

  Uses :one_for_all strategy so if any component crashes,
  the whole service is restarted.
  """
  use Supervisor

  alias LemonServices.Service.Definition

  require Logger

  @doc """
  Starts a service supervisor under the DynamicSupervisor.
  """
  @spec start_service(Definition.t()) :: DynamicSupervisor.on_start_child()
  def start_service(%Definition{} = definition) do
    # Check if already running
    case Registry.lookup(LemonServices.Registry, {:service_supervisor, definition.id}) do
      [{pid, _}] when is_pid(pid) ->
        {:error, :already_running}

      [] ->
        spec = %{
          id: {__MODULE__, definition.id},
          start: {__MODULE__, :start_link, [definition]},
          restart: :transient,
          type: :supervisor
        }

        DynamicSupervisor.start_child(
          LemonServices.Runtime.Supervisor,
          spec
        )
    end
  end

  @doc """
  Stops a running service supervisor.
  """
  @spec stop_service(atom()) :: :ok | {:error, :not_running}
  def stop_service(service_id) when is_atom(service_id) do
    case Registry.lookup(LemonServices.Registry, {:service_supervisor, service_id}) do
      [{pid, _}] when is_pid(pid) ->
        # Terminate the supervisor gracefully
        DynamicSupervisor.terminate_child(
          LemonServices.Runtime.Supervisor,
          pid
        )

      [] ->
        {:error, :not_running}
    end
  end

  @doc """
  Starts the supervisor for a service.
  """
  def start_link(%Definition{} = definition) do
    Supervisor.start_link(__MODULE__, definition, name: via_tuple(definition.id))
  end

  @impl true
  def init(%Definition{} = definition) do
    children = [
      # Log buffer for this service
      {LemonServices.Runtime.LogBuffer, service_id: definition.id},

      # Port manager for the OS process
      {LemonServices.Runtime.PortManager, definition: definition},

      # Health checker (if configured)
      {LemonServices.Runtime.HealthChecker, definition: definition},

      # Main server coordinating everything
      {LemonServices.Runtime.Server, definition: definition}
    ]

    # Filter out nil children (e.g., health checker if not configured)
    children = Enum.reject(children, &is_nil/1)

    Supervisor.init(children, strategy: :one_for_all, max_restarts: definition.max_restarts)
  end

  defp via_tuple(service_id) do
    {:via, Registry, {LemonServices.Registry, {:service_supervisor, service_id}}}
  end
end
