defmodule LemonControlPlane.NodeShells do
  @moduledoc "Bounded, opener-owned shell directory; terminal data never enters general event fanout."
  use GenServer
  require Logger
  alias LemonControlPlane.Protocol.Errors

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def open(params, ctx), do: GenServer.call(__MODULE__, {:open, params, ctx[:conn_pid] || self()}, 35_000)

  def command(operation, params, ctx) do
    owner = ctx[:conn_pid] || self()
    case GenServer.call(__MODULE__, {:lookup, params["shellId"], owner}) do
      {:ok, shell} ->
        args = params |> Map.delete("nodeId") |> Map.put("openInvokeId", shell.invoke_id)
        LemonControlPlane.NodeIO.invoke(shell.node_id, "node.shell." <> operation, args, ctx)
      error -> error
    end
  end

  @impl true
  def init(_), do: {:ok, %{shells: %{}, invocations: %{}}}

  @impl true
  def handle_call({:open, params, owner}, from, state) do
    node_id = params["nodeId"]
    cond do
      not is_binary(node_id) or is_nil(LemonControlPlane.NodeStore.get_node(node_id)) ->
        {:reply, {:error, Errors.not_found("Node not found")}, state}
      map_size(state.shells) >= 64 or Enum.count(state.shells, fn {_, s} -> s.owner == owner end) >= 8 ->
        {:reply, {:error, Errors.unavailable("Shell limit reached")}, state}
      true ->
        shell_id = LemonCore.Id.uuid()
        args = params |> Map.delete("nodeId") |> Map.put("shellId", shell_id)
        case LemonCore.NodeRegistry.invoke(node_id, "node.shell.open", args,
               recipient: self(), timeout_ms: 3_600_000) do
          {:ok, invoke_id} ->
            shell = %{owner: owner, ref: Process.monitor(owner), invoke_id: invoke_id,
              node_id: node_id, pending: from, seq: 0,
              timer: Process.send_after(self(), {:open_timeout, shell_id}, 30_000)}
            Logger.info("node_io operation=node.shell.open dispatched=true redacted=true")
            {:noreply, %{state | shells: Map.put(state.shells, shell_id, shell),
              invocations: Map.put(state.invocations, invoke_id, shell_id)}}
          {:error, _} -> {:reply, {:error, Errors.unavailable("Node is not available")}, state}
        end
    end
  end

  def handle_call({:lookup, id, owner}, _from, state) do
    case Map.get(state.shells, id) do
      %{owner: ^owner, pending: nil} = shell -> {:reply, {:ok, shell}, state}
      _ -> {:reply, {:error, Errors.not_found("Shell not found for this connection")}, state}
    end
  end

  @impl true
  def handle_info({:lemon_node_shell_event, invoke_id, payload}, state) do
    id = state.invocations[invoke_id]
    case state.shells[id] do
      nil -> {:noreply, state}
      shell ->
        case payload do
          %{"type" => "ready"} when not is_nil(shell.pending) ->
            Process.cancel_timer(shell.timer)
            GenServer.reply(shell.pending, {:ok, %{"shellId" => id}})
            {:noreply, put_in(state.shells[id].pending, nil)}
          %{"type" => "output", "seq" => seq, "dataBase64" => data} when seq == shell.seq + 1 ->
            case Process.info(shell.owner, :message_queue_len) do
              {:message_queue_len, length} when length < 512 ->
                send(shell.owner, {:event, "node.shell.output", %{"shellId" => id, "dataBase64" => data, "seq" => seq}})
                {:noreply, put_in(state.shells[id].seq, seq)}
              _ ->
                LemonCore.NodeRegistry.cancel(shell.invoke_id, :slow_consumer)
                {:noreply, remove(state, id)}
            end
          %{"type" => "exit", "code" => code} ->
            send(shell.owner, {:event, "node.shell.exit", %{"shellId" => id, "code" => code}})
            {:noreply, remove(state, id)}
          _ -> {:noreply, state}
        end
    end
  end

  def handle_info({:lemon_node_result, invoke_id, _result}, state) do
    id = state.invocations[invoke_id]
    if shell = state.shells[id] do
      send(shell.owner, {:event, "node.shell.exit", %{"shellId" => id, "code" => 124}})
    end
    {:noreply, remove(state, id)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = Enum.reduce(state.shells, state, fn {id, shell}, acc ->
      if shell.ref == ref do
        LemonCore.NodeRegistry.cancel(shell.invoke_id, :connection_closed)
        remove(acc, id)
      else
        acc
      end
    end)
    {:noreply, state}
  end

  def handle_info({:open_timeout, id}, state) do
    if shell = state.shells[id], do: LemonCore.NodeRegistry.cancel(shell.invoke_id, :open_timeout)
    {:noreply, remove(state, id)}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.shells, fn {_, shell} -> LemonCore.NodeRegistry.cancel(shell.invoke_id, :shell_service_stopped) end)
    :ok
  end

  defp remove(state, id) do
    case Map.pop(state.shells, id) do
      {nil, _} -> state
      {shell, shells} ->
        Process.cancel_timer(shell.timer)
        Process.demonitor(shell.ref, [:flush])
        if shell.pending, do: GenServer.reply(shell.pending, {:error, Errors.unavailable("PTY failed to open")})
        %{state | shells: shells, invocations: Map.delete(state.invocations, shell.invoke_id)}
    end
  end
end
