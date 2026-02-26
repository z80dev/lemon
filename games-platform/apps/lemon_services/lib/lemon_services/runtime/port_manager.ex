defmodule LemonServices.Runtime.PortManager do
  @moduledoc """
  Manages the OS port (process) for a service.

  Handles:
  - Starting shell commands or Elixir modules
  - Sending input to the process
  - Receiving stdout/stderr output
  - Graceful shutdown
  """
  use GenServer

  alias LemonServices.Service.Definition

  require Logger

  # Client API

  def start_link(opts) do
    definition = Keyword.fetch!(opts, :definition)
    GenServer.start_link(__MODULE__, definition, name: via_tuple(definition.id))
  end

  @doc """
  Starts a port for the given service definition.
  """
  @spec start_port(Definition.t()) :: {:ok, port()} | {:error, term()}
  def start_port(%Definition{} = definition) do
    GenServer.call(via_tuple(definition.id), :start_port)
  end

  @doc """
  Stops a running port.
  """
  @spec stop_port(atom(), non_neg_integer()) :: :ok
  def stop_port(service_id, timeout_ms \\ 5000) when is_atom(service_id) do
    GenServer.call(via_tuple(service_id), {:stop_port, timeout_ms})
  end

  @doc """
  Sends input to the port.
  """
  @spec send_input(atom(), iodata()) :: :ok | {:error, :not_running}
  def send_input(service_id, data) when is_atom(service_id) do
    GenServer.call(via_tuple(service_id), {:send_input, data})
  end

  @doc """
  Gets the port process PID.
  """
  @spec get_port_pid(atom()) :: pid() | nil
  def get_port_pid(service_id) when is_atom(service_id) do
    GenServer.call(via_tuple(service_id), :get_port_pid)
  end

  # Server Callbacks

  @impl true
  def init(%Definition{} = definition) do
    {:ok, %{
      definition: definition,
      port: nil,
      os_pid: nil,
      owner: nil
    }}
  end

  @impl true
  def handle_call(:start_port, {pid, _ref}, state) do
    if state.port do
      {:reply, {:ok, state.port}, state}
    else
      case do_start_port(state.definition, pid) do
        {:ok, port, os_pid} ->
          new_state = %{state | port: port, os_pid: os_pid, owner: pid}
          {:reply, {:ok, port}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:stop_port, timeout_ms}, _from, state) do
    new_state = do_stop_port(state, timeout_ms)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:send_input, data}, _from, state) do
    if state.port do
      Port.command(state.port, data)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_call(:get_port_pid, _from, state) do
    # The port itself doesn't have a PID, but we return our own
    # so callers can monitor us
    {:reply, self(), state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    # Forward data to the owner (Server)
    send(state.owner, {:port_data, data})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    exit_code = Bitwise.bsr(status, 8)
    Logger.debug("Port exited with status #{status} (exit code #{exit_code})")

    # Forward to owner
    send(state.owner, {:port_exit, exit_code})

    {:noreply, %{state | port: nil, os_pid: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp do_start_port(%Definition{command: {:shell, cmd}} = definition, owner) when is_binary(cmd) do
    start_shell_port(cmd, definition, owner)
  end

  defp do_start_port(%Definition{command: {:shell, args}} = definition, owner) when is_list(args) do
    # Join args for shell execution
    cmd = Enum.join(args, " ")
    start_shell_port(cmd, definition, owner)
  end

  defp do_start_port(%Definition{command: {:module, mod, fun, args}}, _owner) do
    # For Elixir modules, we spawn a separate process that runs the function
    # This is useful for pure-Elixir services
    {:ok, spawn_link(fn ->
      apply(mod, fun, args)
    end), nil}
  end

  defp start_shell_port(cmd, definition, _owner) do
    # Expand working directory (handle ~)
    working_dir =
      if definition.working_dir do
        Path.expand(definition.working_dir)
      else
        File.cwd!()
      end

    # Build environment
    env =
      (definition.env || %{})
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    # Spawn the port
    # Use :spawn_executable with a shell to get proper process group handling
    port = Port.open(
      {:spawn, "cd #{working_dir} && #{cmd}"},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        env: env,
        cd: working_dir
      ]
    )

    # Try to get the OS PID
    os_pid = get_os_pid(port)

    {:ok, port, os_pid}
  rescue
    e ->
      Logger.error("Failed to start port: #{inspect(e)}")
      {:error, e}
  end

  defp do_stop_port(%{port: nil} = state, _timeout_ms) do
    state
  end

  defp do_stop_port(%{port: port, os_pid: os_pid} = state, timeout_ms) do
    # Try graceful shutdown first (SIGTERM)
    if os_pid do
      System.cmd("kill", ["-TERM", "#{os_pid}"])
    else
      Port.close(port)
    end

    # Wait for process to exit
    receive do
      {^port, {:exit_status, _}} ->
        :ok
    after
      timeout_ms ->
        # Force kill if still running
        if os_pid do
          System.cmd("kill", ["-KILL", "#{os_pid}"])
        end
        Port.close(port)
    end

    %{state | port: nil, os_pid: nil}
  end

  defp get_os_pid(port) do
    # This is a hack to get the OS PID from a port
    # In practice, we might need a different approach
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  defp via_tuple(service_id) do
    {:via, Registry, {LemonServices.Registry, {:port_manager, service_id}}}
  end
end
