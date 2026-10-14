defmodule LemonControlPlane.Presence do
  @moduledoc """
  Presence tracker for connected control plane clients.

  Tracks all connected WebSocket clients and provides:
  - Connection registration/unregistration
  - Role-based counting (operators, nodes)
  - Client lookup by connection ID
  - Broadcasting events to all connected clients
  """

  use GenServer

  require Logger

  @type client_info :: %{
          role: atom(),
          client_id: String.t() | nil,
          pid: pid(),
          connected_at: integer()
        }

  ## Client API

  @doc """
  Starts the presence tracker.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new connection.
  """
  @spec register(String.t(), map()) :: :ok
  def register(conn_id, info) do
    GenServer.call(__MODULE__, {:register, conn_id, info})
  end

  @doc """
  Unregisters a connection.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(conn_id) do
    GenServer.call(__MODULE__, {:unregister, conn_id})
  end

  @doc """
  Gets info for a connection.
  """
  @spec get(String.t()) :: client_info() | nil
  def get(conn_id) do
    GenServer.call(__MODULE__, {:get, conn_id})
  end

  @doc """
  Lists all connected clients.
  """
  @spec list() :: [{String.t(), client_info()}]
  def list do
    GenServer.call(__MODULE__, :list)
  end

  @doc """
  Returns counts by role.
  """
  @spec counts() :: %{total: integer(), operators: integer(), nodes: integer()}
  def counts do
    GenServer.call(__MODULE__, :counts)
  end

  @doc """
  Broadcasts an event to all connected clients.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(event_name, payload) do
    GenServer.cast(__MODULE__, {:broadcast, event_name, payload})
  end

  @doc """
  Broadcasts an event to clients matching a filter.
  """
  @spec broadcast(String.t(), term(), (client_info() -> boolean())) :: :ok
  def broadcast(event_name, payload, filter_fn) do
    GenServer.cast(__MODULE__, {:broadcast, event_name, payload, filter_fn})
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # ETS table for fast lookups
    table = :ets.new(:presence_table, [:set, :protected])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, conn_id, info}, _from, state) do
    case :ets.lookup(state.table, conn_id) do
      [{^conn_id, previous}] -> release_client(previous)
      [] -> :ok
    end

    client_info =
      info
      |> Map.put(:delivery, Map.get(info, :delivery) || LemonCore.Bus.Delivery.new(info.pid))
      |> Map.put(:monitor_ref, Process.monitor(info.pid))
      |> Map.put(:connected_at, System.system_time(:millisecond))

    :ets.insert(state.table, {conn_id, client_info})

    Logger.debug("Presence: registered #{conn_id} (role: #{info.role})")

    # Emit presence_changed event to bus
    emit_presence_changed(state.table)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, conn_id}, _from, state) do
    case :ets.lookup(state.table, conn_id) do
      [{^conn_id, info}] -> release_client(info)
      [] -> :ok
    end

    :ets.delete(state.table, conn_id)

    Logger.debug("Presence: unregistered #{conn_id}")

    # Emit presence_changed event to bus
    emit_presence_changed(state.table)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, conn_id}, _from, state) do
    result =
      case :ets.lookup(state.table, conn_id) do
        [{^conn_id, info}] -> info
        [] -> nil
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    clients = :ets.tab2list(state.table)
    {:reply, clients, state}
  end

  @impl true
  def handle_call(:counts, _from, state) do
    clients = :ets.tab2list(state.table)

    counts =
      Enum.reduce(clients, %{total: 0, operators: 0, nodes: 0}, fn {_id, info}, acc ->
        acc = %{acc | total: acc.total + 1}

        case info.role do
          :operator -> %{acc | operators: acc.operators + 1}
          :node -> %{acc | nodes: acc.nodes + 1}
          _ -> acc
        end
      end)

    {:reply, counts, state}
  end

  @impl true
  def handle_cast({:broadcast, event_name, payload}, state) do
    do_broadcast(state.table, event_name, payload, fn _ -> true end)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:broadcast, event_name, payload, filter_fn}, state) do
    do_broadcast(state.table, event_name, payload, filter_fn)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    removed =
      Enum.reduce(:ets.tab2list(state.table), false, fn
        {conn_id, %{monitor_ref: ^ref, pid: ^pid} = info}, _removed ->
          release_client(info)
          :ets.delete(state.table, conn_id)
          true

        _, removed ->
          removed
      end)

    if removed, do: emit_presence_changed(state.table)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp release_client(info) do
    LemonCore.Bus.Delivery.close(info.delivery)
    Process.demonitor(info.monitor_ref, [:flush])
  end

  defp do_broadcast(table, event_name, payload, filter_fn) do
    clients = :ets.tab2list(table)

    for {_conn_id, info} <- clients, filter_fn.(info) do
      LemonCore.Bus.Delivery.send(info.delivery, {:event, event_name, payload})
    end

    :ok
  end

  # Emit presence_changed event to the bus for EventBridge to pick up
  defp emit_presence_changed(table) do
    clients = :ets.tab2list(table)

    connections =
      Enum.map(clients, fn {conn_id, info} ->
        %{
          conn_id: conn_id,
          role: info.role,
          client_id: info[:client_id],
          connected_at: info[:connected_at]
        }
      end)

    payload = %{
      connections: connections,
      count: length(clients)
    }

    # Broadcast to the bus - EventBridge subscribes to "presence" topic
    if Code.ensure_loaded?(LemonCore.Bus) do
      event = LemonCore.Event.new(:presence_changed, payload)
      LemonCore.Bus.broadcast("presence", event)
    end
  rescue
    _ -> :ok
  end
end
