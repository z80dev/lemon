defmodule LemonCore.NodeRegistry do
  @moduledoc """
  Live registry and targeted invocation broker for named Lemon execution nodes.

  Nodes are registered by the control-plane WebSocket connection after node
  authentication. Runtime code can then address a node by its human-readable
  name without depending on the control-plane application.

  The registry deliberately tracks live connections only. Pairing credentials
  and durable node metadata remain owned by the control plane; a node is
  executable only while its authenticated connection is registered here.
  """

  use GenServer

  @default_timeout_ms 30 * 60 * 1_000

  @type node_info :: %{
          id: String.t(),
          name: String.t(),
          pid: pid(),
          metadata: map(),
          connected_at_ms: integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(String.t(), String.t(), pid(), map()) :: :ok | {:error, term()}
  def register(node_id, name, pid, metadata \\ %{})
      when is_binary(node_id) and is_binary(name) and is_pid(pid) and is_map(metadata) do
    GenServer.call(__MODULE__, {:register, node_id, String.trim(name), pid, metadata})
  end

  @spec unregister(String.t(), pid()) :: :ok
  def unregister(node_id, pid) when is_binary(node_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:unregister, node_id, pid})
  end

  @doc "Renames a live node without disturbing its connection or invocations."
  @spec rename(String.t(), String.t()) :: :ok | {:error, term()}
  def rename(node_id, name) when is_binary(node_id) and is_binary(name) do
    GenServer.call(__MODULE__, {:rename, node_id, String.trim(name)})
  end

  @spec list() :: [node_info()]
  def list, do: GenServer.call(__MODULE__, :list)

  @spec resolve(String.t()) :: {:ok, node_info()} | {:error, :not_found}
  def resolve(name_or_id) when is_binary(name_or_id) do
    GenServer.call(__MODULE__, {:resolve, String.trim(name_or_id)})
  end

  @spec online?(String.t()) :: boolean()
  def online?(name_or_id) when is_binary(name_or_id) do
    match?({:ok, _node}, resolve(name_or_id))
  end

  @doc """
  Starts an invocation on a named node and returns immediately.

  The recipient receives one of:

      {:lemon_node_result, invoke_id, {:ok, result}}
      {:lemon_node_result, invoke_id, {:error, reason}}
  """
  @spec invoke(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def invoke(name_or_id, method, args, opts \\ [])
      when is_binary(name_or_id) and is_binary(method) and is_map(args) do
    recipient = Keyword.get(opts, :recipient, self())
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    GenServer.call(
      __MODULE__,
      {:invoke, String.trim(name_or_id), method, args, recipient, timeout_ms}
    )
  end

  @spec cancel(String.t(), term()) :: :ok
  def cancel(invoke_id, reason \\ :cancelled) when is_binary(invoke_id) do
    GenServer.call(__MODULE__, {:cancel, invoke_id, reason})
  end

  @spec complete(String.t(), String.t(), term(), term()) :: :ok | {:error, term()}
  def complete(node_id, invoke_id, result, error \\ nil)
      when is_binary(node_id) and is_binary(invoke_id) do
    GenServer.call(__MODULE__, {:complete, node_id, invoke_id, result, error})
  end

  @doc "Pushes an event directly to one live node connection."
  @spec push(String.t(), String.t(), map()) :: :ok | {:error, :not_found}
  def push(name_or_id, event_name, payload)
      when is_binary(name_or_id) and is_binary(event_name) and is_map(payload) do
    GenServer.call(__MODULE__, {:push, String.trim(name_or_id), event_name, payload})
  end

  @impl true
  def init(_opts) do
    {:ok, %{nodes: %{}, names: %{}, invocations: %{}}}
  end

  @impl true
  def handle_call({:register, _node_id, "", _pid, _metadata}, _from, state) do
    {:reply, {:error, :invalid_name}, state}
  end

  def handle_call({:register, node_id, name, pid, metadata}, _from, state) do
    case Map.get(state.names, name) do
      existing_id when is_binary(existing_id) and existing_id != node_id ->
        {:reply, {:error, {:name_taken, name}}, state}

      _ ->
        state = remove_node(state, node_id, :reconnected)
        monitor_ref = Process.monitor(pid)

        node = %{
          id: node_id,
          name: name,
          pid: pid,
          metadata: metadata,
          connected_at_ms: System.system_time(:millisecond),
          monitor_ref: monitor_ref
        }

        state = %{
          state
          | nodes: Map.put(state.nodes, node_id, node),
            names: Map.put(state.names, name, node_id)
        }

        {:reply, :ok, state}
    end
  end

  def handle_call({:unregister, node_id, pid}, _from, state) do
    state =
      case Map.get(state.nodes, node_id) do
        %{pid: ^pid} -> remove_node(state, node_id, :disconnected)
        _ -> state
      end

    {:reply, :ok, state}
  end

  def handle_call({:rename, _node_id, ""}, _from, state) do
    {:reply, {:error, :invalid_name}, state}
  end

  def handle_call({:rename, node_id, name}, _from, state) do
    case {Map.get(state.nodes, node_id), Map.get(state.names, name)} do
      {nil, _existing_id} ->
        {:reply, {:error, :not_found}, state}

      {_node, existing_id} when is_binary(existing_id) and existing_id != node_id ->
        {:reply, {:error, {:name_taken, name}}, state}

      {node, _existing_id} ->
        renamed = %{node | name: name}

        state = %{
          state
          | nodes: Map.put(state.nodes, node_id, renamed),
            names: state.names |> Map.delete(node.name) |> Map.put(name, node_id)
        }

        {:reply, :ok, state}
    end
  end

  def handle_call(:list, _from, state) do
    nodes =
      state.nodes
      |> Map.values()
      |> Enum.map(&public_node/1)
      |> Enum.sort_by(& &1.name)

    {:reply, nodes, state}
  end

  def handle_call({:resolve, name_or_id}, _from, state) do
    {:reply, resolve_node(state, name_or_id), state}
  end

  def handle_call({:push, name_or_id, event_name, payload}, _from, state) do
    case resolve_node(state, name_or_id) do
      {:ok, node} ->
        send(node.pid, {:node_event, event_name, payload})
        {:reply, :ok, state}

      {:error, :not_found} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:invoke, name_or_id, method, args, recipient, timeout_ms},
        _from,
        state
      ) do
    cond do
      not is_pid(recipient) ->
        {:reply, {:error, :invalid_recipient}, state}

      not is_integer(timeout_ms) or timeout_ms <= 0 ->
        {:reply, {:error, :invalid_timeout}, state}

      true ->
        case resolve_node(state, name_or_id) do
          {:ok, node} ->
            invoke_id = LemonCore.Id.uuid()
            timer_ref = Process.send_after(self(), {:invoke_timeout, invoke_id}, timeout_ms)
            recipient_ref = Process.monitor(recipient)

            invocation = %{
              id: invoke_id,
              node_id: node.id,
              node_pid: node.pid,
              recipient: recipient,
              recipient_ref: recipient_ref,
              timer_ref: timer_ref,
              method: method
            }

            payload = %{
              "invokeId" => invoke_id,
              "nodeId" => node.id,
              "nodeName" => node.name,
              "method" => method,
              "args" => args,
              "timeoutMs" => timeout_ms
            }

            send(node.pid, {:node_event, "node.invoke.request", payload})

            {:reply, {:ok, invoke_id},
             %{state | invocations: Map.put(state.invocations, invoke_id, invocation)}}

          {:error, :not_found} ->
            {:reply, {:error, {:node_offline, name_or_id}}, state}
        end
    end
  end

  def handle_call({:cancel, invoke_id, reason}, _from, state) do
    case Map.pop(state.invocations, invoke_id) do
      {nil, _invocations} ->
        {:reply, :ok, state}

      {invocation, invocations} ->
        cancel_invocation_monitors(invocation)
        cancel_remote_invocation(state, invoke_id, invocation, reason)
        notify(invocation, {:error, reason})
        {:reply, :ok, %{state | invocations: invocations}}
    end
  end

  def handle_call({:complete, node_id, invoke_id, result, error}, _from, state) do
    case Map.get(state.invocations, invoke_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{node_id: expected_node_id} when expected_node_id != node_id ->
        {:reply, {:error, :wrong_node}, state}

      invocation ->
        cancel_invocation_monitors(invocation)
        reply = if is_nil(error), do: {:ok, result}, else: {:error, {:remote, error}}
        notify(invocation, reply)

        {:reply, :ok, %{state | invocations: Map.delete(state.invocations, invoke_id)}}
    end
  end

  @impl true
  def handle_info({:invoke_timeout, invoke_id}, state) do
    case Map.pop(state.invocations, invoke_id) do
      {nil, _invocations} ->
        {:noreply, state}

      {invocation, invocations} ->
        Process.demonitor(invocation.recipient_ref, [:flush])
        cancel_remote_invocation(state, invoke_id, invocation, :timeout)
        notify(invocation, {:error, :timeout})
        {:noreply, %{state | invocations: invocations}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.nodes, fn {_id, node} -> node.monitor_ref == ref end) do
      {node_id, _node} ->
        {:noreply, remove_node(state, node_id, :disconnected)}

      nil ->
        invocations =
          Enum.reduce(state.invocations, state.invocations, fn {invoke_id, invocation}, acc ->
            if invocation.recipient_ref == ref do
              Process.cancel_timer(invocation.timer_ref)
              cancel_remote_invocation(state, invoke_id, invocation, :recipient_down)
              Map.delete(acc, invoke_id)
            else
              acc
            end
          end)

        {:noreply, %{state | invocations: invocations}}
    end
  end

  defp resolve_node(state, name_or_id) do
    node_id = Map.get(state.names, name_or_id, name_or_id)

    case Map.get(state.nodes, node_id) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  defp public_node(node) do
    Map.take(node, [:id, :name, :pid, :metadata, :connected_at_ms])
  end

  defp remove_node(state, node_id, reason) do
    case Map.pop(state.nodes, node_id) do
      {nil, _nodes} ->
        state

      {node, nodes} ->
        Process.demonitor(node.monitor_ref, [:flush])

        {removed, kept} =
          Enum.split_with(state.invocations, fn {_invoke_id, invocation} ->
            invocation.node_id == node_id
          end)

        Enum.each(removed, fn {invoke_id, invocation} ->
          cancel_invocation_monitors(invocation)
          cancel_remote_invocation(state, invoke_id, invocation, {:node_disconnected, reason})
          notify(invocation, {:error, {:node_disconnected, reason}})
        end)

        %{
          state
          | nodes: nodes,
            names: Map.delete(state.names, node.name),
            invocations: Map.new(kept)
        }
    end
  end

  defp cancel_invocation_monitors(invocation) do
    Process.cancel_timer(invocation.timer_ref)
    Process.demonitor(invocation.recipient_ref, [:flush])
    :ok
  end

  defp notify(invocation, result) do
    send(invocation.recipient, {:lemon_node_result, invocation.id, result})
  end

  # Bind cancellation to the same live connection that received the request.
  # A reconnect replaces the registered pid and must not receive cancellation
  # for work that belonged to the superseded socket.
  defp cancel_remote_invocation(state, invoke_id, invocation, reason) do
    case Map.get(state.nodes, invocation.node_id) do
      %{pid: pid} when pid == invocation.node_pid ->
        send(pid, {
          :node_event,
          "node.invoke.cancel",
          %{"invokeId" => invoke_id, "reason" => inspect(reason)}
        })

      _ ->
        :ok
    end
  end
end
