defmodule LemonServices.Runtime.Server do
  @moduledoc """
  Main GenServer for managing a service lifecycle.

  Coordinates between:
  - PortManager (the actual OS process)
  - HealthChecker (health status)
  - LogBuffer (log storage)
  - PubSub (event broadcasting)

  Handles restart policies and crash recovery.
  """
  use GenServer

  alias LemonServices.Service.{Definition, State}
  alias LemonServices.Runtime.{PortManager, LogBuffer}

  require Logger

  # Restart delays in ms (exponential backoff)
  @restart_delays [1000, 2000, 5000, 10000, 30000]

  # Client API

  def start_link(opts) do
    definition = Keyword.fetch!(opts, :definition)
    GenServer.start_link(__MODULE__, definition, name: via_tuple(definition.id))
  end

  @doc """
  Gets the current state of a service.
  """
  @spec get_state(atom()) :: {:ok, State.t()} | {:error, :not_running}
  def get_state(service_id) when is_atom(service_id) do
    case Registry.lookup(LemonServices.Registry, {:server, service_id}) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get_state)}
      [] -> {:error, :not_running}
    end
  end

  @doc """
  Stops a running service.
  """
  @spec stop(atom(), non_neg_integer()) :: :ok | {:error, :not_running}
  def stop(service_id, timeout_ms \\ 5000) when is_atom(service_id) do
    case Registry.lookup(LemonServices.Registry, {:server, service_id}) do
      [{pid, _}] -> GenServer.call(pid, {:stop, timeout_ms})
      [] -> {:error, :not_running}
    end
  end

  @doc """
  Subscribes a process to log output.
  """
  @spec subscribe_logs(atom(), pid()) :: :ok | {:error, :not_running}
  def subscribe_logs(service_id, subscriber_pid) when is_atom(service_id) do
    case Registry.lookup(LemonServices.Registry, {:server, service_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:subscribe_logs, subscriber_pid})
      [] -> {:error, :not_running}
    end
  end

  @doc """
  Unsubscribes a process from log output.
  """
  @spec unsubscribe_logs(atom(), pid()) :: :ok | {:error, :not_running}
  def unsubscribe_logs(service_id, subscriber_pid) when is_atom(service_id) do
    case Registry.lookup(LemonServices.Registry, {:server, service_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:unsubscribe_logs, subscriber_pid})
      [] -> {:error, :not_running}
    end
  end

  @doc """
  Subscribes a process to service events.
  """
  @spec subscribe_events(atom(), pid()) :: :ok | {:error, :not_running}
  def subscribe_events(service_id, subscriber_pid) when is_atom(service_id) do
    case Registry.lookup(LemonServices.Registry, {:server, service_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:subscribe_events, subscriber_pid})
      [] -> {:error, :not_running}
    end
  end

  @doc """
  Unsubscribes a process from service events.
  """
  @spec unsubscribe_events(atom(), pid()) :: :ok | {:error, :not_running}
  def unsubscribe_events(service_id, subscriber_pid) when is_atom(service_id) do
    case Registry.lookup(LemonServices.Registry, {:server, service_id}) do
      [{pid, _}] -> GenServer.cast(pid, {:unsubscribe_events, subscriber_pid})
      [] -> {:error, :not_running}
    end
  end

  # Server Callbacks

  @impl true
  def init(%Definition{} = definition) do
    state = State.new(definition)

    # Register ourselves in the Registry
    Registry.register(LemonServices.Registry, definition.id, self())

    # Start the service immediately
    send(self(), :do_start)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:stop, timeout_ms}, _from, state) do
    new_state = do_stop(state, timeout_ms)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:subscribe_logs, pid}, state) do
    new_state = State.add_log_subscriber(state, pid)
    # Send recent logs to catch up
    send_recent_logs(state.definition.id, pid)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:unsubscribe_logs, pid}, state) do
    new_state = State.remove_log_subscriber(state, pid)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:subscribe_events, pid}, state) do
    new_state = State.add_event_subscriber(state, pid)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:unsubscribe_events, pid}, state) do
    new_state = State.remove_event_subscriber(state, pid)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:do_start, state) do
    new_state = do_start(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{pid: pid} = state) do
    # The service process crashed
    Logger.warning("Service #{state.definition.id} process crashed: #{inspect(reason)}")

    new_state =
      state
      |> State.set_status(:crashed, error: reason, exit_code: extract_exit_code(reason))
      |> State.increment_restart_count()

    broadcast_event(state, {:service_crashed, new_state.last_exit_code, reason})

    # Handle restart policy
    case handle_restart_policy(new_state) do
      {:restart, delay} ->
        Logger.info("Restarting service #{state.definition.id} in #{delay}ms (attempt #{new_state.restart_count})")
        Process.send_after(self(), :do_start, delay)
        {:noreply, new_state}

      :no_restart ->
        Logger.info("Not restarting service #{state.definition.id} due to restart policy")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Some other process we were monitoring died, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info({:port_data, data}, state) do
    # Log data from the port
    log_line = %{
      timestamp: DateTime.utc_now(),
      stream: :stdout,
      data: data
    }

    LogBuffer.append(state.definition.id, log_line)
    broadcast_log(state, log_line)
    {:noreply, state}
  end

  @impl true
  def handle_info({:port_error, data}, state) do
    # Error data from the port
    log_line = %{
      timestamp: DateTime.utc_now(),
      stream: :stderr,
      data: data
    }

    LogBuffer.append(state.definition.id, log_line)
    broadcast_log(state, log_line)
    {:noreply, state}
  end

  @impl true
  def handle_info({:port_exit, exit_code}, state) do
    Logger.info("Service #{state.definition.id} exited with code #{exit_code}")

    new_state =
      state
      |> State.set_status(:stopped, exit_code: exit_code)
      |> Map.put(:port, nil)
      |> Map.put(:pid, nil)

    broadcast_event(state, {:service_exited, exit_code})

    # Handle restart policy for normal exit
    case handle_restart_policy(new_state) do
      {:restart, delay} ->
        Process.send_after(self(), :do_start, delay)
        {:noreply, new_state}

      :no_restart ->
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:health_check, :healthy}, state) do
    new_state = State.set_health(state, :healthy)
    broadcast_event(state, :health_check_passed)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:health_check, :unhealthy, reason}, state) do
    new_state = State.set_health(state, :unhealthy)
    broadcast_event(state, {:health_check_failed, reason})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:health_check, :starting}, state) do
    # Health checker is starting up
    {:noreply, state}
  end

  # Private functions

  defp do_start(state) do
    Logger.info("Starting service #{state.definition.id}")

    new_state = State.set_status(state, :starting)
    broadcast_event(state, :service_starting)

    case PortManager.start_port(state.definition) do
      {:ok, port} ->
        # Monitor the port process
        port_pid = PortManager.get_port_pid(state.definition.id)
        Process.monitor(port_pid)

        new_state =
          %{new_state |
            port: port,
            pid: port_pid
          }
          |> State.set_status(:running)

        broadcast_event(state, :service_started)
        new_state

      {:error, reason} ->
        Logger.error("Failed to start service #{state.definition.id}: #{inspect(reason)}")

        new_state =
          new_state
          |> State.set_status(:crashed, error: reason)
          |> State.increment_restart_count()

        broadcast_event(state, {:service_failed_to_start, reason})

        # Schedule restart if policy allows
        case handle_restart_policy(new_state) do
          {:restart, delay} ->
            Process.send_after(self(), :do_start, delay)
          :no_restart ->
            :ok
        end

        new_state
    end
  end

  defp do_stop(state, timeout_ms) do
    Logger.info("Stopping service #{state.definition.id}")

    new_state = State.set_status(state, :stopping)
    broadcast_event(state, :service_stopping)

    if state.port do
      PortManager.stop_port(state.definition.id, timeout_ms)
    end

    new_state =
      new_state
      |> State.set_status(:stopped)
      |> Map.put(:port, nil)
      |> Map.put(:pid, nil)

    broadcast_event(state, :service_stopped)
    new_state
  end

  defp handle_restart_policy(%{definition: %{restart_policy: :temporary}}), do: :no_restart
  defp handle_restart_policy(%{definition: %{restart_policy: :permanent}} = state) do
    delay = Enum.at(@restart_delays, min(state.restart_count, length(@restart_delays) - 1))
    {:restart, delay}
  end
  defp handle_restart_policy(%{definition: %{restart_policy: :transient}, last_exit_code: 0}), do: :no_restart
  defp handle_restart_policy(%{definition: %{restart_policy: :transient}} = state) do
    delay = Enum.at(@restart_delays, min(state.restart_count, length(@restart_delays) - 1))
    {:restart, delay}
  end

  defp extract_exit_code({:exit_status, status}), do: Bitwise.bsr(status, 8)
  defp extract_exit_code(_), do: nil

  defp broadcast_event(state, event) do
    Phoenix.PubSub.broadcast(
      LemonServices.PubSub,
      "service:#{state.definition.id}",
      {:service_event, state.definition.id, event}
    )

    Phoenix.PubSub.broadcast(
      LemonServices.PubSub,
      "services:all",
      {:service_event, state.definition.id, event}
    )

    # Direct notification to event subscribers
    for pid <- state.event_subscribers do
      send(pid, {:service_event, state.definition.id, event})
    end
  end

  defp broadcast_log(state, log_line) do
    Phoenix.PubSub.broadcast(
      LemonServices.PubSub,
      "service:#{state.definition.id}:logs",
      {:service_log, state.definition.id, log_line}
    )

    # Direct notification to log subscribers
    for pid <- state.log_subscribers do
      send(pid, {:service_log, state.definition.id, log_line})
    end
  end

  defp send_recent_logs(service_id, pid) do
    logs = LogBuffer.get_logs(service_id, 100)
    for log <- logs do
      send(pid, {:service_log, service_id, log})
    end
  end

  defp via_tuple(service_id) do
    {:via, Registry, {LemonServices.Registry, {:server, service_id}}}
  end
end
