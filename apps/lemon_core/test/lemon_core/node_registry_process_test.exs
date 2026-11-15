defmodule LemonCore.NodeRegistryProcessTest do
  use ExUnit.Case, async: false

  alias LemonCore.NodeRegistry
  alias LemonCore.NodeRegistry.Generations

  setup do
    id = "process-node-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :sys.replace_state(Generations, fn state ->
        :ets.delete(Generations, id)
        state
      end)
    end)

    %{node_id: id}
  end

  test "traced streamed frames call only their invocation owner", %{node_id: id} do
    :ok = NodeRegistry.register_session(id, id, self(), 1)
    {:ok, invoke_id} = NodeRegistry.invoke_node(id, "coding_agent.run", %{})
    [{owner, {:invocation, ^id}}] = Registry.lookup(NodeRegistry.Invocations, invoke_id)
    tracer = spawn_link(fn -> collect_traces([]) end)
    on_exit(fn -> Process.exit(tracer, :kill) end)

    :erlang.trace(self(), true, [:send, {:tracer, tracer}])

    try do
      for seq <- 1..3 do
        assert {:ok, :accepted} =
                 NodeRegistry.event_session(id, self(), 1, invoke_id, seq, %{"type" => "delta"})
      end
    after
      :erlang.trace(self(), false, [:send])
    end

    barrier = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _, ^barrier}
    send(tracer, {:collect, self()})
    assert_receive {:traces, traces}

    targets =
      for {:trace, _, :send, {:"$gen_call", _, _}, target} <- traces,
          do: target

    assert targets == [owner, owner, owner]
    assert :ok = NodeRegistry.cancel(invoke_id)
  end

  test "a blocked invocation cannot stall another stream", %{node_id: id} do
    :ok = NodeRegistry.register_session(id, id, self(), 1)
    {:ok, blocked_id} = NodeRegistry.invoke_node(id, "coding_agent.run", %{})
    {:ok, live_id} = NodeRegistry.invoke_node(id, "coding_agent.run", %{})
    [{blocked, _}] = Registry.lookup(NodeRegistry.Invocations, blocked_id)
    :ok = :sys.suspend(blocked)

    try do
      assert {:ok, :accepted} =
               NodeRegistry.event_session(id, self(), 1, live_id, 1, %{"type" => "started"})

      assert_receive {:lemon_node_event, ^live_id, 1, %{"type" => "started"}}
      assert :ok = NodeRegistry.cancel(live_id)
    after
      :sys.resume(blocked)
      NodeRegistry.cancel(blocked_id)
    end
  end

  test "socket death removes its own Registry entry and retains its generation floor", %{
    node_id: id
  } do
    parent = self()

    socket =
      spawn(fn ->
        :ok = NodeRegistry.register_session(id, id, self(), 4, %{capabilities: %{}})
        {:links, [partition]} = Process.info(self(), :links)
        send(parent, {:registered, self(), partition})

        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(socket, :kill) end)
    assert_receive {:registered, ^socket, partition}

    assert [{^socket, %{name: ^id, generation: 4, metadata: %{capabilities: %{}}}}] =
             Registry.lookup(NodeRegistry.Connections, id)

    assert {:ok, invoke_id} = NodeRegistry.invoke_node(id, "coding_agent.run", %{})
    [{invocation, _}] = Registry.lookup(NodeRegistry.Invocations, invoke_id)
    assert invocation != Process.whereis(NodeRegistry)
    assert {:monitors, invocation_monitors} = Process.info(invocation, :monitors)
    assert {:process, socket} in invocation_monitors
    assert {:process, self()} in invocation_monitors
    assert Process.read_timer(:sys.get_state(invocation).timer_ref) > 0
    assert {:monitors, monitors} = Process.info(Process.whereis(NodeRegistry), :monitors)
    refute {:process, socket} in monitors

    :erlang.trace(partition, true, [:receive])

    try do
      send(socket, :stop)
      assert_receive {:trace, ^partition, :receive, {:EXIT, ^socket, :normal}}
      :sys.get_state(partition)
      assert Registry.lookup(NodeRegistry.Connections, id) == []

      assert_receive {:lemon_node_result, ^invoke_id,
                      {:error, {:node_disconnected, :disconnected}}}

      assert {:error, :not_found} = NodeRegistry.resolve_id(id)
      assert {:error, :stale_session} = NodeRegistry.register_session(id, id, self(), 3)
    after
      :erlang.trace(partition, false, [:receive])
    end
  end

  test "socket-owned handover and rename preserve binding and the generation floor", %{
    node_id: id
  } do
    parent = self()

    old =
      spawn(fn ->
        :ok = NodeRegistry.register_session(id, id, self(), 1)
        send(parent, {:ready, self()})
        socket_loop(parent)
      end)

    on_exit(fn -> Process.exit(old, :kill) end)
    assert_receive {:ready, ^old}
    assert :ok = NodeRegistry.rename(id, id <> "-renamed")
    assert {:ok, %{name: name, pid: ^old}} = NodeRegistry.resolve_id(id)
    assert name == id <> "-renamed"
    assert {:ok, invoke_id} = NodeRegistry.invoke_node(id, "coding_agent.run", %{})
    assert :ok = NodeRegistry.register_session(id, id, self(), 2)
    assert_receive {:old_socket, {:node_session_revoked, ^id, 2}}
    assert_receive {:lemon_node_result, ^invoke_id, {:error, {:node_disconnected, :reconnected}}}

    assert {:error, :terminal} =
             NodeRegistry.event_session(id, old, 1, invoke_id, 1, %{"type" => "started"})

    assert {:error, :terminal} = NodeRegistry.control(invoke_id, :steer, "stale")
    assert :ok = NodeRegistry.cancel(invoke_id)
    refute_receive {:node_event, "node.invoke.cancel", _}
    assert {:error, :stale_session} = NodeRegistry.register_session(id, id, self(), 1)
  end

  defp socket_loop(parent) do
    receive do
      {:node_registry_owner, _, _, _, _} = message ->
        NodeRegistry.handle_owner_message(message)
        socket_loop(parent)

      message ->
        send(parent, {:old_socket, message})
        socket_loop(parent)
    end
  end

  defp collect_traces(traces) do
    receive do
      {:collect, recipient} ->
        send(recipient, {:traces, Enum.reverse(traces)})
        collect_traces([])

      trace ->
        collect_traces([trace | traces])
    end
  end
end
