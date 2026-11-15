defmodule LemonControlPlane.ConnectionsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Connections

  setup do
    # Start Connections if not running
    case Process.whereis(Connections) do
      nil ->
        {:ok, pid} = Connections.start_link([])

        on_exit(fn ->
          # Avoid flakiness: presence can terminate between `Process.alive?/1` and `GenServer.stop/1`.
          if is_pid(pid) do
            try do
              if Process.alive?(pid), do: GenServer.stop(pid)
            catch
              :exit, _ -> :ok
            end
          end
        end)

        {:ok, presence_pid: pid}

      pid ->
        # Clear existing connections
        for {conn_id, _} <- Connections.list() do
          Connections.unregister(conn_id)
        end

        {:ok, presence_pid: pid}
    end
  end

  test "Registry owns membership and removes a dead socket without a presence server" do
    unless Process.whereis(LemonControlPlane.EventBridge),
      do: start_supervised!(LemonControlPlane.EventBridge)

    parent = self()
    conn_id = "registry-owned-#{System.unique_integer([:positive])}"

    socket =
      spawn(fn ->
        :ok = Connections.register(conn_id, %{role: :operator, pid: self()})
        send(parent, {:registered_socket, self()})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(socket, :kill) end)
    assert_receive {:registered_socket, ^socket}
    assert Connections.get(conn_id).pid == socket

    assert [{^socket, {^conn_id, _info}}] =
             Enum.filter(Registry.lookup(Connections, :clients), fn {_pid, {id, _}} ->
               id == conn_id
             end)

    ref = Process.monitor(socket)
    send(socket, :stop)
    assert_receive {:DOWN, ^ref, :process, ^socket, :normal}
    assert Connections.get(conn_id) == nil
  end

  describe "register/2" do
    test "registers a new connection" do
      conn_id = "conn_#{System.unique_integer()}"
      info = %{role: :operator, client_id: "test-client", pid: self()}

      assert :ok = Connections.register(conn_id, info)

      # Verify registered
      client = Connections.get(conn_id)
      assert client.role == :operator
      assert client.client_id == "test-client"
      assert is_integer(client.connected_at)
    end

    test "emits presence_changed event on register" do
      conn_id = "conn_#{System.unique_integer()}"
      info = %{role: :operator, client_id: "test-client", pid: self()}

      # Subscribe to presence topic if Bus is available
      if Code.ensure_loaded?(LemonCore.Bus) do
        LemonCore.Bus.subscribe("presence")

        Connections.register(conn_id, info)

        # Wait for event
        assert_receive %LemonCore.Event{type: :presence_changed, payload: payload}, 1000
        assert payload.count >= 1
        assert is_list(payload.connections)
      end
    end
  end

  describe "unregister/1" do
    test "unregisters a connection" do
      conn_id = "conn_#{System.unique_integer()}"
      info = %{role: :operator, client_id: "test-client", pid: self()}

      Connections.register(conn_id, info)
      assert Connections.get(conn_id) != nil

      assert :ok = Connections.unregister(conn_id)
      assert Connections.get(conn_id) == nil
    end

    test "emits presence_changed event on unregister" do
      conn_id = "conn_#{System.unique_integer()}"
      info = %{role: :operator, client_id: "test-client", pid: self()}

      Connections.register(conn_id, info)

      # Subscribe to presence topic if Bus is available
      if Code.ensure_loaded?(LemonCore.Bus) do
        LemonCore.Bus.subscribe("presence")

        Connections.unregister(conn_id)

        # Wait for event - may receive multiple, find the unregister one
        assert_receive %LemonCore.Event{type: :presence_changed, payload: _payload}, 1000
      end
    end
  end

  describe "list/0" do
    test "returns all registered connections" do
      conn_id1 = "conn_#{System.unique_integer()}"
      conn_id2 = "conn_#{System.unique_integer()}"

      Connections.register(conn_id1, %{role: :operator, client_id: "c1", pid: self()})
      Connections.register(conn_id2, %{role: :node, client_id: "c2", pid: self()})

      list = Connections.list()

      # Find our connections in the list
      conn1 = Enum.find(list, fn {id, _} -> id == conn_id1 end)
      conn2 = Enum.find(list, fn {id, _} -> id == conn_id2 end)

      assert conn1 != nil
      assert conn2 != nil

      {_, info1} = conn1
      {_, info2} = conn2

      assert info1.role == :operator
      assert info2.role == :node
    end
  end

  describe "counts/0" do
    test "returns counts by role" do
      # Register different roles
      Connections.register("op_#{System.unique_integer()}", %{
        role: :operator,
        client_id: "op1",
        pid: self()
      })

      Connections.register("op_#{System.unique_integer()}", %{
        role: :operator,
        client_id: "op2",
        pid: self()
      })

      Connections.register("node_#{System.unique_integer()}", %{
        role: :node,
        client_id: "n1",
        pid: self()
      })

      counts = Connections.counts()

      assert counts.total >= 3
      assert counts.operators >= 2
      assert counts.nodes >= 1
    end
  end

  describe "broadcast/2" do
    test "broadcasts event to all connected clients" do
      # Register ourselves as a client
      conn_id = "conn_#{System.unique_integer()}"
      Connections.register(conn_id, %{role: :operator, client_id: "test", pid: self()})

      # Broadcast an event
      Connections.broadcast("test.event", %{data: "value"})

      # We should receive the event
      assert_receive {:event, "test.event", %{data: "value"}}, 1000
    end
  end

  describe "broadcast/3 with filter" do
    test "broadcasts event only to matching clients" do
      # Register ourselves as operator
      conn_id1 = "conn_#{System.unique_integer()}"
      Connections.register(conn_id1, %{role: :operator, client_id: "test", pid: self()})

      # Broadcast only to nodes (not us)
      Connections.broadcast("node.only.event", %{}, fn info -> info.role == :node end)

      # We should NOT receive the event (we're operator)
      refute_receive {:event, "node.only.event", _}, 100

      # Now broadcast to operators
      Connections.broadcast("operator.event", %{}, fn info -> info.role == :operator end)

      # We should receive this one
      assert_receive {:event, "operator.event", _}, 1000
    end
  end
end
