defmodule LemonControlPlane.Connections do
  @moduledoc """
  Connection-owned membership in a duplicate-key Registry.

  Sockets register themselves and unregister on graceful disconnect; Registry
  removes membership on owner death. Fan-out dispatches directly over Registry
  entries, retaining bounded `LemonCore.Bus.Delivery` admission.
  """

  alias LemonCore.Bus.Delivery

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  def start_link(_opts \\ []) do
    Registry.start_link(keys: :duplicate, name: __MODULE__)
  end

  def register(conn_id, info) do
    unregister(conn_id)

    info =
      info
      |> Map.put(:delivery, Map.get(info, :delivery) || Delivery.new(info.pid))
      |> Map.put(:connected_at, System.system_time(:millisecond))

    {:ok, _} = Registry.register(__MODULE__, :clients, {conn_id, info})

    # This monitor is only a presence-change notification, never membership or
    # resource ownership: Registry and Delivery own their own cleanup.
    if bridge = Process.whereis(LemonControlPlane.EventBridge),
      do: send(bridge, {:connection_registered, self()})

    emit_changed()
    :ok
  end

  def unregister(conn_id) do
    if Process.whereis(__MODULE__) do
      entries =
        for {owner, {^conn_id, info}} <- Registry.lookup(__MODULE__, :clients),
            owner == self(),
            do: info

      Enum.each(entries, &Delivery.close(&1.delivery))
      Registry.unregister_match(__MODULE__, :clients, {conn_id, :_})
      if entries != [], do: emit_changed()
    end

    :ok
  end

  def get(conn_id) do
    Enum.find_value(list(), fn {id, info} -> if id == conn_id, do: info end)
  end

  def list do
    if Process.whereis(__MODULE__) do
      for {_owner, {id, info}} <- Registry.lookup(__MODULE__, :clients),
          Process.alive?(info.pid),
          do: {id, info}
    else
      []
    end
  end

  def watch_session(key) do
    entry = {:session_watch, self()}
    Registry.unregister(__MODULE__, entry)
    {:ok, _} = Registry.register(__MODULE__, entry, key)
    :ok
  end

  def watched_session(pid) do
    case Registry.lookup(__MODULE__, {:session_watch, pid}) do
      [{^pid, key}] -> key
      _ -> nil
    end
  end

  def counts do
    Enum.reduce(list(), %{total: 0, operators: 0, nodes: 0}, fn {_id, info}, counts ->
      counts = %{counts | total: counts.total + 1}

      case info.role do
        :operator -> %{counts | operators: counts.operators + 1}
        :node -> %{counts | nodes: counts.nodes + 1}
        _ -> counts
      end
    end)
  end

  def dispatch(fun) do
    if Process.whereis(__MODULE__) do
      Registry.dispatch(__MODULE__, :clients, fn entries ->
        fun.(for {_pid, value} <- entries, do: value)
      end)
    end

    :ok
  end

  def broadcast(name, payload, filter \\ fn _ -> true end) do
    dispatch(fn entries ->
      for {_id, info} <- entries,
          filter.(info),
          do: Delivery.send(info.delivery, {:event, name, payload})
    end)
  end

  def emit_changed do
    connections =
      Enum.map(list(), fn {id, info} ->
        %{
          conn_id: id,
          role: info.role,
          client_id: info[:client_id],
          connected_at: info.connected_at
        }
      end)

    LemonCore.Bus.broadcast(
      "presence",
      LemonCore.Event.new(:presence_changed, %{
        connections: connections,
        count: length(connections)
      })
    )
  end
end
