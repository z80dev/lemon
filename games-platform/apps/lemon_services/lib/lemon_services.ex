defmodule LemonServices do
  @moduledoc """
  Public API for LemonServices - long-running service management.

  LemonServices provides a service-oriented process management system
  built on OTP. Services are:

  - **Named**: Looked up by atom ID (e.g., `:dev_server`)
  - **Persistent**: Outlive individual sessions
  - **Observable**: Stream logs and events via PubSub
  - **Healthy**: Built-in health check support
  - **Resilient**: Configurable restart policies

  ## Quick Start

      # Define a service
      {:ok, definition} = LemonServices.Service.Definition.new(
        id: :my_server,
        name: "My Server",
        command: {:shell, "npm run dev"},
        working_dir: "~/my-app",
        auto_start: true
      )

      # Register the definition
      :ok = LemonServices.register_definition(definition)

      # Start the service (if not auto-started)
      {:ok, _pid} = LemonServices.start_service(:my_server)

      # Check status
      {:ok, state} = LemonServices.get_service(:my_server)

      # Stream logs
      LemonServices.subscribe_to_logs(:my_server)

      # Stop the service
      :ok = LemonServices.stop_service(:my_server)

  ## Service Lifecycle

  Services go through the following states:

  - `:pending` - Service defined but not started
  - `:starting` - Service is being started
  - `:running` - Service is running
  - `:unhealthy` - Service running but health check failing
  - `:stopping` - Service is being stopped
  - `:stopped` - Service stopped normally
  - `:crashed` - Service crashed (may restart based on policy)

  ## Restart Policies

  - `:permanent` - Always restart (default for critical services)
  - `:transient` - Restart only on abnormal exit (default)
  - `:temporary` - Never restart (for one-off tasks)

  ## Events

  Services broadcast events via PubSub:

  - `{:service_event, service_id, :service_starting}`
  - `{:service_event, service_id, :service_started}`
  - `{:service_event, service_id, :service_stopping}`
  - `{:service_event, service_id, :service_stopped}`
  - `{:service_event, service_id, {:service_crashed, exit_code, reason}}`
  - `{:service_event, service_id, :health_check_passed}`
  - `{:service_event, service_id, {:health_check_failed, reason}}`

  Subscribe to events:

      Phoenix.PubSub.subscribe(LemonServices.PubSub, "service:my_server")
      Phoenix.PubSub.subscribe(LemonServices.PubSub, "services:all")

  ## Log Streaming

  Log lines are broadcast on the `service:{id}:logs` topic:

      Phoenix.PubSub.subscribe(LemonServices.PubSub, "service:my_server:logs")

  Log format:

      {:service_log, service_id, %{timestamp: DateTime.t(), stream: :stdout | :stderr, data: String.t()}}

  """

  alias LemonServices.Service.{Definition, State, Store}
  alias LemonServices.Runtime.{Supervisor, Server, LogBuffer}

  require Logger

  # ============================================================================
  # Service Lifecycle
  # ============================================================================

  @doc """
  Starts a service by its definition or ID.

  ## Examples

      # Start by ID (must be registered first)
      {:ok, pid} = LemonServices.start_service(:dev_server)

      # Start by definition directly
      {:ok, pid} = LemonServices.start_service(definition)

  """
  @spec start_service(Definition.t() | atom()) :: {:ok, pid()} | {:error, term()}
  def start_service(%Definition{} = definition) do
    # Ensure definition is registered
    :ok = Store.register_definition(definition)

    # Start the service
    case Supervisor.start_service(definition) do
      {:ok, _pid} = ok -> ok
      {:ok, _pid, _info} = ok -> ok
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  def start_service(service_id) when is_atom(service_id) do
    case Store.get_definition(service_id) do
      {:ok, definition} ->
        start_service(definition)

      {:error, :not_found} ->
        {:error, :definition_not_found}
    end
  end

  @doc """
  Stops a running service.

  ## Options

  - `:timeout` - Graceful shutdown timeout in ms (default: 5000)

  ## Examples

      :ok = LemonServices.stop_service(:dev_server)
      :ok = LemonServices.stop_service(:dev_server, timeout: 10000)

  """
  @spec stop_service(atom(), keyword()) :: :ok | {:error, :not_running}
  def stop_service(service_id, opts \\ []) when is_atom(service_id) do
    timeout = Keyword.get(opts, :timeout, 5000)

    case Server.stop(service_id, timeout) do
      :ok ->
        # Also stop the supervisor
        Supervisor.stop_service(service_id)

      {:error, :not_running} ->
        {:error, :not_running}
    end
  end

  @doc """
  Restarts a service.

  ## Examples

      {:ok, pid} = LemonServices.restart_service(:dev_server)

  """
  @spec restart_service(atom()) :: {:ok, pid()} | {:error, term()}
  def restart_service(service_id) when is_atom(service_id) do
    with :ok <- stop_service(service_id),
         # Give it a moment to fully stop
         :ok <- Process.sleep(100) do
      start_service(service_id)
    end
  end

  @doc """
  Kills a service immediately (SIGKILL).

  Use this when graceful shutdown fails.

  ## Examples

      :ok = LemonServices.kill_service(:dev_server)

  """
  @spec kill_service(atom()) :: :ok | {:error, term()}
  def kill_service(service_id) when is_atom(service_id) do
    # Stop with 0 timeout forces immediate kill
    stop_service(service_id, timeout: 0)
  end

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  Lists all service definitions.

  ## Examples

      definitions = LemonServices.list_definitions()

  """
  @spec list_definitions() :: [Definition.t()]
  def list_definitions do
    Store.list_definitions()
  end

  @doc """
  Lists all running services with their current state.

  ## Examples

      services = LemonServices.list_services()

  """
  @spec list_services() :: [State.t()]
  def list_services do
    # Get all registered definitions
    definitions = Store.list_definitions()

    # Get state for each
    Enum.flat_map(definitions, fn definition ->
      case get_service(definition.id) do
        {:ok, state} -> [state]
        {:error, :not_running} -> []
      end
    end)
  end

  @doc """
  Lists services filtered by tags.

  ## Examples

      dev_services = LemonServices.list_services_by_tag(:dev)
      infra_services = LemonServices.list_services_by_tag([:infra, :database])

  """
  @spec list_services_by_tag(atom() | [atom()]) :: [State.t()]
  def list_services_by_tag(tags) when is_list(tags) do
    list_services()
    |> Enum.filter(fn state ->
      Enum.any?(tags, &(&1 in state.definition.tags))
    end)
  end

  def list_services_by_tag(tag) when is_atom(tag) do
    list_services_by_tag([tag])
  end

  @doc """
  Gets the current state of a service.

  ## Examples

      {:ok, state} = LemonServices.get_service(:dev_server)
      {:error, :not_running} = LemonServices.get_service(:unknown)

  """
  @spec get_service(atom()) :: {:ok, State.t()} | {:error, :not_running}
  def get_service(service_id) when is_atom(service_id) do
    Server.get_state(service_id)
  end

  @doc """
  Gets the status of a service.

  ## Examples

      :running = LemonServices.service_status(:dev_server)
      {:error, :not_running} = LemonServices.service_status(:unknown)

  """
  @spec service_status(atom()) :: State.status() | {:error, :not_running}
  def service_status(service_id) when is_atom(service_id) do
    case get_service(service_id) do
      {:ok, state} -> state.status
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Checks if a service is running.

  ## Examples

      true = LemonServices.running?(:dev_server)

  """
  @spec running?(atom()) :: boolean()
  def running?(service_id) when is_atom(service_id) do
    case service_status(service_id) do
      status when status in [:running, :unhealthy] -> true
      _ -> false
    end
  end

  # ============================================================================
  # Logs
  # ============================================================================

  @doc """
  Gets the last N log lines from a service.

  ## Examples

      logs = LemonServices.get_logs(:dev_server, 50)

  """
  @spec get_logs(atom(), non_neg_integer()) :: [map()]
  def get_logs(service_id, count \\ 100) when is_atom(service_id) do
    LogBuffer.get_logs(service_id, count)
  end

  @doc """
  Subscribes the calling process to log output from a service.

  The process will receive messages:

      {:service_log, service_id, %{timestamp: DateTime.t(), stream: :stdout | :stderr, data: String.t()}}

  ## Examples

      :ok = LemonServices.subscribe_to_logs(:dev_server)

  """
  @spec subscribe_to_logs(atom()) :: :ok | {:error, :not_running}
  def subscribe_to_logs(service_id) when is_atom(service_id) do
    Server.subscribe_logs(service_id, self())
  end

  @doc """
  Unsubscribes the calling process from log output.

  ## Examples

      :ok = LemonServices.unsubscribe_from_logs(:dev_server)

  """
  @spec unsubscribe_from_logs(atom()) :: :ok | {:error, :not_running}
  def unsubscribe_from_logs(service_id) when is_atom(service_id) do
    Server.unsubscribe_logs(service_id, self())
  end

  # ============================================================================
  # Events
  # ============================================================================

  @doc """
  Subscribes the calling process to service events.

  The process will receive messages:

      {:service_event, service_id, event}

  Where event is one of:
  - `:service_starting`
  - `:service_started`
  - `:service_stopping`
  - `:service_stopped`
  - `{:service_crashed, exit_code, reason}`
  - `:health_check_passed`
  - `{:health_check_failed, reason}`

  ## Examples

      :ok = LemonServices.subscribe_to_events(:dev_server)
      :ok = LemonServices.subscribe_to_events(:all)  # All services

  """
  @spec subscribe_to_events(atom() | :all) :: :ok
  def subscribe_to_events(:all) do
    Phoenix.PubSub.subscribe(LemonServices.PubSub, "services:all")
  end

  def subscribe_to_events(service_id) when is_atom(service_id) do
    Phoenix.PubSub.subscribe(LemonServices.PubSub, "service:#{service_id}")
  end

  @doc """
  Unsubscribes the calling process from service events.

  ## Examples

      :ok = LemonServices.unsubscribe_from_events(:dev_server)
      :ok = LemonServices.unsubscribe_from_events(:all)

  """
  @spec unsubscribe_from_events(atom() | :all) :: :ok
  def unsubscribe_from_events(:all) do
    Phoenix.PubSub.unsubscribe(LemonServices.PubSub, "services:all")
  end

  def unsubscribe_from_events(service_id) when is_atom(service_id) do
    Phoenix.PubSub.unsubscribe(LemonServices.PubSub, "service:#{service_id}")
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  @doc """
  Registers a service definition.

  This makes the service available to start.

  ## Examples

      :ok = LemonServices.register_definition(definition)

  """
  @spec register_definition(Definition.t()) :: :ok | {:error, String.t()}
  def register_definition(%Definition{} = definition) do
    Store.register_definition(definition)
  end

  @doc """
  Unregisters a service definition.

  The service must be stopped first.

  ## Examples

      :ok = LemonServices.unregister_definition(:my_service)

  """
  @spec unregister_definition(atom()) :: :ok | {:error, term()}
  def unregister_definition(service_id) when is_atom(service_id) do
    # Check if running
    if running?(service_id) do
      {:error, :service_running}
    else
      Store.unregister_definition(service_id)
      LemonServices.Config.remove_definition(service_id)
    end
  end

  @doc """
  Gets a service definition by ID.

  ## Examples

      {:ok, definition} = LemonServices.get_definition(:dev_server)

  """
  @spec get_definition(atom()) :: {:ok, Definition.t()} | {:error, :not_found}
  def get_definition(service_id) when is_atom(service_id) do
    Store.get_definition(service_id)
  end

  @doc """
  Saves a service definition to persistent storage.

  Only works for definitions with `persistent: true`.

  ## Examples

      :ok = LemonServices.save_definition(definition)

  """
  @spec save_definition(Definition.t()) :: :ok | {:error, term()}
  def save_definition(%Definition{} = definition) do
    with :ok <- Store.register_definition(definition) do
      LemonServices.Config.save_definition(definition)
    end
  end

  @doc """
  Creates a new service definition at runtime.

  ## Options

  Same as `Definition.new/1`.

  ## Examples

      {:ok, service} = LemonServices.define_service(
        id: :temp_worker,
        name: "Temporary Worker",
        command: {:shell, "python worker.py"},
        persistent: false
      )

  """
  @spec define_service(keyword()) :: {:ok, Definition.t()} | {:error, String.t()}
  def define_service(attrs) do
    with {:ok, definition} <- Definition.new(attrs),
         :ok <- Store.register_definition(definition) do
      {:ok, definition}
    end
  end
end
