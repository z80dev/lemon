defmodule CodingAgent.ExecutionNode.PTY do
  @moduledoc """
  Connection-owned real PTY. The helper reads at most one unacknowledged 16 KiB
  output chunk, caps output at 32 MiB and kills the shell process group on EOF.
  Python 3 is required; no pipe-backed pseudo-terminal fallback is used.
  """
  use GenServer

  def start_link(owner, invoke_id, args, opts) do
    GenServer.start_link(__MODULE__, {owner, invoke_id, args, opts})
  end

  def command(pid, operation, args), do: GenServer.call(pid, {:command, operation, args})
  def ack(pid), do: GenServer.cast(pid, :ack)

  @impl true
  def init({owner, invoke_id, args, opts}) do
    with {:ok, cwd} <- CodingAgent.ExecutionNode.HostIO.resolve(args["cwd"] || opts[:default_cwd], opts),
         true <- File.dir?(cwd),
         {:ok, cols, rows} <- dimensions(args),
         python when is_binary(python) <- System.find_executable("python3"),
         shell when is_binary(shell) <- System.get_env("SHELL") || System.find_executable("sh"),
         true <- File.regular?(shell) do
      helper = Path.join(to_string(:code.priv_dir(:coding_agent)), "node_pty.py")
      port = Port.open({:spawn_executable, python}, [
        :binary, :exit_status, {:packet, 4},
        {:args, [helper, cwd, shell, Integer.to_string(cols), Integer.to_string(rows)]}
      ])
      {:ok, %{owner: owner, ref: Process.monitor(owner), invoke_id: invoke_id,
        port: port, seq: 0, exited: false, timer: Process.send_after(self(), :timeout, 3_600_000)}}
    else
      {:error, reason} -> {:stop, reason}
      _ -> {:stop, :pty_unavailable}
    end
  end

  @impl true
  def handle_call({:command, "input", args}, _from, state) do
    case args["dataBase64"] do
      data when is_binary(data) and byte_size(data) <= 1_398_104 ->
        case Base.decode64(data) do
          {:ok, bytes} when byte_size(bytes) <= 1_048_576 ->
            {:reply, write(state, %{"type" => "input", "dataBase64" => data}), state}
          _ -> {:reply, {:error, :invalid_input}, state}
        end
      _ -> {:reply, {:error, :invalid_input}, state}
    end
  end

  def handle_call({:command, "resize", args}, _from, state) do
    case dimensions(args) do
      {:ok, cols, rows} ->
        {:reply, write(state, %{"type" => "resize", "cols" => cols, "rows" => rows}), state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:command, "close", _args}, _from, state) do
    _ = write(state, %{"type" => "close"})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:ack, state) do
    _ = write(state, %{"type" => "ack"})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Jason.decode(data) do
      {:ok, %{"type" => "ready"}} ->
        send(state.owner, {:node_pty, state.invoke_id, "ready", %{}})
        {:noreply, state}
      {:ok, %{"type" => "output", "dataBase64" => encoded}} when byte_size(encoded) <= 21_848 ->
        seq = state.seq + 1
        send(state.owner, {:node_pty, state.invoke_id, "output", %{"dataBase64" => encoded, "seq" => seq}})
        {:noreply, %{state | seq: seq}}
      {:ok, %{"type" => "exit", "code" => code}} when is_integer(code) ->
        send(state.owner, {:node_pty, state.invoke_id, "exit", %{"code" => code}})
        {:noreply, %{state | exited: true}}
      _ -> {:stop, :invalid_pty_frame, state}
    end
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state), do: {:stop, :normal, state}
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{ref: ref} = state), do: {:stop, :normal, state}
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    Process.cancel_timer(state.timer)
    if not state.exited, do: send(state.owner, {:node_pty, state.invoke_id, "exit", %{"code" => 124}})
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp dimensions(args) do
    cols = args["cols"] || 80
    rows = args["rows"] || 24
    if is_integer(cols) and cols in 1..500 and is_integer(rows) and rows in 1..500,
      do: {:ok, cols, rows}, else: {:error, :invalid_dimensions}
  end

  defp write(state, frame) do
    if Port.command(state.port, Jason.encode!(frame), [:nosuspend]), do: :ok, else: {:error, :pty_busy}
  rescue
    ArgumentError -> {:error, :pty_closed}
  end
end
