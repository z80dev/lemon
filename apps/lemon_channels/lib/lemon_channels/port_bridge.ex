defmodule LemonChannels.PortBridge do
  @moduledoc """
  Owns a Node bridge port. Automatic port restart/replay is the default (XMTP).
  With `restart: :manual` (WhatsApp), port failures emit `bridge_down`; only an
  explicit connect command reopens the port, leaving all retry policy to its owner.

  Stop and port exit synchronously terminate the bridge's process group through
  `LemonCore.ProcessGroup.terminate/2` before closing the port or scheduling a
  restart. This includes descendants that ignore stdin EOF; the port's OS pid is
  discarded after cleanup rather than retained for delayed signalling.
  """

  @behaviour GenServer

  require Logger

  @restart_delay_ms 2_000

  @type bridge_spec :: %{
          required(:label) => String.t(),
          required(:event_tag) => atom(),
          required(:script_filename) => String.t()
        }

  @type state :: %{
          port: port() | nil,
          os_pid: pos_integer() | nil,
          buffer: String.t(),
          notify_pid: pid() | nil,
          unavailable_reason: term() | nil,
          script_path: String.t(),
          connect_command: map() | nil,
          bridge: bridge_spec(),
          restart: :automatic | :manual
        }

  @spec start_link({bridge_spec(), keyword()}) :: GenServer.on_start()
  def start_link({bridge, opts}) do
    GenServer.start_link(__MODULE__, {bridge, opts})
  end

  @spec command(pid(), map()) :: :ok
  def command(server, command) when is_pid(server) and is_map(command) do
    GenServer.cast(server, {:command, command})
  end

  @doc "Terminates the current port's group and forgets its remembered connect command."
  @spec stop_port(pid()) :: :ok
  def stop_port(server), do: GenServer.call(server, :stop_port)

  @impl true
  def init({bridge, opts}) do
    Process.flag(:trap_exit, true)
    cfg = normalize_config(Keyword.get(opts, :config, %{}))

    state = %{
      port: nil,
      os_pid: nil,
      buffer: "",
      notify_pid: Keyword.get(opts, :notify_pid),
      unavailable_reason: nil,
      script_path: script_path(cfg, bridge),
      connect_command: nil,
      bridge: bridge,
      restart: Keyword.get(opts, :restart, :automatic)
    }

    {:ok, maybe_open_port(state)}
  end

  @impl true
  def handle_call(:stop_port, _from, state) do
    close_port(state)

    {:reply, :ok,
     %{
       state
       | port: nil,
         os_pid: nil,
         buffer: "",
         connect_command: nil,
         unavailable_reason: :stopped
     }}
  end

  @impl true
  def handle_cast(
        {:command, %{"op" => "connect"} = command},
        %{port: nil, restart: :manual} = state
      ) do
    state = maybe_open_port(%{state | connect_command: nil})

    if is_port(state.port) do
      handle_cast({:command, command}, state)
    else
      {:noreply, state}
    end
  end

  def handle_cast({:command, %{} = command}, %{port: port} = state) when is_port(port) do
    state = remember_connect_command(state, command)

    case write_command(port, command) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        emit_error(state, "failed to write command to #{bridge_label(state)} bridge", %{
          reason: inspect(reason)
        })

        {:noreply, state}
    end
  end

  def handle_cast({:command, %{} = command}, state) do
    state = remember_connect_command(state, command)

    emit_error(state, "#{bridge_label(state)} bridge unavailable", %{
      op: Map.get(command, "op") || Map.get(command, :op),
      reason: inspect(state.unavailable_reason)
    })

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    state = %{state | buffer: state.buffer <> data}
    {lines, remainder} = split_lines(state.buffer)
    state = %{state | buffer: remainder}

    state = Enum.reduce(lines, state, &handle_line/2)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    close_port(state)

    Logger.warning("#{bridge_label(state)} bridge exited (status=#{status})")

    emit_error(state, "#{bridge_label(state)} bridge exited", %{status: status})

    state = %{
      state
      | port: nil,
        os_pid: nil,
        buffer: "",
        unavailable_reason: {:exit_status, status}
    }

    case state.restart do
      :automatic -> Process.send_after(self(), :restart_port, @restart_delay_ms)
      :manual -> send_event(state, %{"type" => "bridge_down"})
    end

    {:noreply, state}
  end

  def handle_info(:restart_port, %{port: nil, restart: :automatic} = state) do
    {:noreply, maybe_open_port(state)}
  end

  def handle_info(:restart_port, state) do
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state)
    :ok
  end

  defp close_port(%{port: port, os_pid: os_pid}) when is_port(port) do
    if is_integer(os_pid), do: LemonCore.ProcessGroup.terminate(os_pid, [])

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  defp close_port(_state), do: :ok

  defp maybe_open_port(state) do
    with {:ok, node_path} <- node_path(),
         :ok <- validate_script_path(state.script_path) do
      port =
        Port.open({:spawn_executable, node_path}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :hide,
          {:args, [state.script_path]}
        ])

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      state
      |> Map.merge(%{port: port, os_pid: os_pid, buffer: "", unavailable_reason: nil})
      |> replay_connect_command()
    else
      {:error, reason} ->
        emit_error(state, "failed to start #{bridge_label(state)} bridge", %{reason: reason})
        if state.restart == :manual, do: send_event(state, %{"type" => "bridge_down"})
        %{state | port: nil, unavailable_reason: reason}
    end
  end

  defp node_path do
    case System.find_executable("node") do
      nil -> {:error, "node executable not found on PATH"}
      path -> {:ok, path}
    end
  end

  defp script_path(cfg, bridge) do
    from_cfg = Map.get(cfg, :bridge_script) || Map.get(cfg, "bridge_script")

    cond do
      is_binary(from_cfg) and String.trim(from_cfg) != "" ->
        Path.expand(String.trim(from_cfg))

      true ->
        default_script_path(bridge)
    end
  end

  defp default_script_path(%{script_filename: filename}) do
    Application.app_dir(:lemon_channels, "priv/#{filename}")
  end

  defp validate_script_path(path) when is_binary(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, "bridge script not found: #{path}"}
    end
  end

  defp validate_script_path(_), do: {:error, "bridge script path is invalid"}

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n", trim: false)

    case Enum.split(parts, -1) do
      {lines, [last]} ->
        cleaned =
          lines
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {cleaned, last}

      _ ->
        {[], buffer}
    end
  end

  defp handle_line(line, state) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{} = event} ->
        send_event(state, event)
        state

      {:ok, other} ->
        emit_error(state, "#{bridge_label(state)} bridge emitted non-object JSON", %{
          payload: other
        })

        state

      {:error, _reason} ->
        emit_error(state, "#{bridge_label(state)} bridge emitted invalid JSON", %{line: line})
        state
    end
  end

  defp send_event(%{notify_pid: pid, bridge: %{event_tag: event_tag}}, event) when is_pid(pid) do
    send(pid, {event_tag, event})
  end

  defp send_event(_state, _event), do: :ok

  defp emit_error(state, message, extra) do
    payload =
      %{"type" => "error", "message" => message}
      |> Map.merge(stringify_keys(extra || %{}))

    send_event(state, payload)
  end

  defp replay_connect_command(%{port: port, connect_command: %{} = command} = state)
       when is_port(port) do
    case write_command(port, command) do
      :ok ->
        state

      {:error, reason} ->
        emit_error(state, "failed to replay #{bridge_label(state)} connect command", %{
          reason: inspect(reason)
        })

        %{state | unavailable_reason: {:connect_replay_failed, reason}}
    end
  end

  defp replay_connect_command(state), do: state

  defp remember_connect_command(state, %{} = command) do
    if connect_command?(command) do
      %{state | connect_command: command}
    else
      state
    end
  end

  defp connect_command?(%{} = command) do
    (Map.get(command, "op") || Map.get(command, :op)) == "connect"
  end

  defp write_command(port, command) when is_port(port) and is_map(command) do
    encoded = Jason.encode!(command) <> "\n"

    case Port.command(port, encoded) do
      true -> :ok
      false -> {:error, :port_closed}
    end
  rescue
    error -> {:error, error}
  end

  defp bridge_label(%{bridge: %{label: label}}), do: label

  defp stringify_keys(value), do: LemonCore.MapHelpers.stringify_keys(value)

  defp normalize_config(cfg) when is_map(cfg), do: cfg

  defp normalize_config(cfg) when is_list(cfg) do
    if Keyword.keyword?(cfg), do: Enum.into(cfg, %{}), else: %{}
  end

  defp normalize_config(_), do: %{}
end
