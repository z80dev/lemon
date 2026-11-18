defmodule LemonControlPlane.EventBridgeBackpressureTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.{EventBridge, Connections}
  alias LemonControlPlane.WS.Connection
  alias LemonCore.{Bus, Event}
  alias LemonCore.Bus.Delivery

  @operator_auth %{
    role: :operator,
    scopes: [:admin, :read, :write, :approvals, :pairing, :content]
  }

  setup do
    for module <- [Connections, EventBridge] do
      unless Process.whereis(module), do: start_supervised!(module)
    end

    :ok
  end

  test "fanout works while the Registry supervisor is suspended without a presence call" do
    conn_id = "dispatch-only-#{System.unique_integer([:positive])}"
    :ok = Connections.register(conn_id, %{role: :operator, auth: @operator_auth, pid: self()})
    state = :sys.get_state(EventBridge)
    registry = Process.whereis(Connections)
    :ok = :sys.suspend(registry)

    try do
      task =
        Task.async(fn ->
          EventBridge.handle_info(
            Event.new(:delta, %{run_id: "dispatch-only", seq: 1, text: "registry dispatch"}),
            state
          )
        end)

      assert {:noreply, _} = Task.await(task, 1000)
      assert_receive {:event, "chat", %{"text" => "registry dispatch"}, _}
    after
      :sys.resume(registry)
      Connections.unregister(conn_id)
    end
  end

  test "inline fanout bounds a frozen socket and does not delay another client" do
    slow = frozen_consumer()
    healthy = frozen_consumer()
    suffix = System.unique_integer([:positive])
    slow_id = "pressure-slow-#{suffix}"
    healthy_id = "pressure-healthy-#{suffix}"

    :ok =
      Connections.register(slow_id, %{
        role: :operator,
        auth: @operator_auth,
        client_id: "slow",
        pid: slow,
        delivery: Delivery.new(slow, max_queue: 4)
      })

    :ok =
      Connections.register(healthy_id, %{
        role: :operator,
        auth: @operator_auth,
        client_id: "healthy",
        pid: healthy,
        delivery: Delivery.new(healthy, max_queue: 2048)
      })

    on_exit(fn ->
      if Process.whereis(Connections) do
        Connections.unregister(slow_id)
        Connections.unregister(healthy_id)
      end
    end)

    state = :sys.get_state(EventBridge)

    for seq <- 1..1000 do
      event =
        Event.new(:delta, %{run_id: "pressure-run", seq: seq, text: "small delta"}, %{
          session_key: "pressure-session"
        })

      assert {:noreply, _} = EventBridge.handle_info(event, state)
    end

    # Fanout is synchronous admission, not an asynchronously unbounded set of
    # tasks. Completion of this callback is the producer-side synchronization.
    assert {:message_queue_len, 5} = Process.info(slow, :message_queue_len)
    slow_events = drain(slow)
    assert Enum.count(slow_events, &(&1 == {:stream_resync, :overflow})) == 1
    assert Enum.count(slow_events, &match?({:event, "chat", _, _}, &1)) <= 4
    healthy_events = drain(healthy)
    assert Enum.count(healthy_events, &match?({:event, "chat", _, _}, &1)) == 1000
  end

  test "overlapping Bus admissions keep every WebSocket client connected" do
    suffix = System.unique_integer([:positive])
    run_id = "concurrent-bridge-run-#{suffix}"
    sockets = for n <- 1..2, do: {"concurrent-bridge-#{suffix}-#{n}", frozen_consumer()}

    for {id, socket} <- sockets do
      :ok =
        Connections.register(id, %{
          role: :operator,
          auth: @operator_auth,
          client_id: id,
          pid: socket
        })
    end

    EventBridge.subscribe_run(run_id)
    bridge = Process.whereis(EventBridge)
    %{delivery: delivery} = :sys.get_state(bridge)
    parent = self()

    on_exit(fn ->
      if Process.whereis(Connections) do
        for {id, _socket} <- sockets, do: Connections.unregister(id)
      end

      if Process.whereis(EventBridge), do: EventBridge.unsubscribe_run(run_id)
    end)

    :ok = :sys.suspend(bridge)

    try do
      # Hold the serializer so both real broadcasts are pending together.
      true = :erlang.suspend_process(delivery.admitter)

      publishers =
        try do
          publishers =
            for seq <- 1..2 do
              spawn_monitor(fn ->
                receive do
                  :publish ->
                    :ok =
                      Bus.broadcast(
                        Bus.run_topic(run_id),
                        Event.new(:delta, %{run_id: run_id, seq: seq, text: "delta-#{seq}"})
                      )
                end
              end)
            end

          for {pid, _ref} <- publishers do
            :erlang.trace(pid, true, [:send, {:tracer, parent}])
            send(pid, :publish)
          end

          admitter = delivery.admitter

          for {pid, _ref} <- publishers do
            assert_receive {:trace, ^pid, :send, {:admit, ^pid, _ref, _event}, ^admitter},
                           1000

            :erlang.trace(pid, false, [:send])
          end

          refute Delivery.closed?(delivery)
          publishers
        after
          :erlang.resume_process(delivery.admitter)
        end

      for {pid, ref} <- publishers,
          do: assert_receive({:DOWN, ^ref, :process, ^pid, :normal}, 1000)
    after
      :sys.resume(bridge)
    end

    %{delivery: current} = :sys.get_state(bridge)
    assert Delivery.matches?(current, delivery.gate)
    refute Delivery.closed?(current)

    for {id, socket} <- sockets do
      refute Delivery.closed?(Connections.get(id).delivery)
      events = drain(socket)
      refute {:stream_resync, :overflow} in events

      assert ["delta-1", "delta-2"] ==
               events
               |> Enum.flat_map(fn
                 {:event, "chat", %{"text" => text}, _version} -> [text]
                 _ -> []
               end)
               |> Enum.sort()
    end
  end

  test "bridge Bus ingress bounds a suspended bridge and signals recovery before rebinding" do
    socket = frozen_consumer()
    suffix = System.unique_integer([:positive])
    conn_id = "bridge-pressure-#{suffix}"
    run_id = "bridge-pressure-run-#{suffix}"

    :ok =
      Connections.register(conn_id, %{
        role: :operator,
        auth: @operator_auth,
        client_id: "pressure",
        pid: socket
      })

    EventBridge.subscribe_run(run_id)
    bridge = Process.whereis(EventBridge)
    before = :sys.get_state(bridge)

    on_exit(fn ->
      if Process.whereis(Connections), do: Connections.unregister(conn_id)
      if Process.whereis(EventBridge), do: EventBridge.unsubscribe_run(run_id)
    end)

    :ok = :sys.suspend(bridge)

    for seq <- 1..1000 do
      Bus.broadcast(
        Bus.run_topic(run_id),
        Event.new(:delta, %{run_id: run_id, seq: seq, text: "small"})
      )
    end

    assert {:message_queue_len, count} = Process.info(bridge, :message_queue_len)
    assert count <= 257
    :ok = :sys.resume(bridge)
    :sys.get_state(bridge)
    events = drain(socket)
    assert Enum.count(events, &(&1 == {:stream_resync, :overflow})) == 1

    # Reconnect can finish while an old publisher is delayed before send/2.
    # Old data and even its overflow marker cannot fence a fresh recipient.
    fresh = frozen_consumer()
    fresh_id = "bridge-reconnected-#{suffix}"

    :ok =
      Connections.register(fresh_id, %{
        role: :operator,
        auth: @operator_auth,
        client_id: "reconnected",
        pid: fresh
      })

    on_exit(fn -> if Process.whereis(Connections), do: Connections.unregister(fresh_id) end)
    event = Event.new(:delta, %{run_id: run_id, seq: 1001, text: "obsolete"})
    send(bridge, {:lemon_bus_delivery, before.delivery.gate, event})
    send(bridge, {:lemon_bus_delivery, before.delivery.gate, {:stream_resync, :overflow}})

    Bus.broadcast(
      Bus.run_topic(run_id),
      Event.new(:delta, %{run_id: run_id, seq: 1002, text: "current"})
    )

    :sys.get_state(bridge)
    refute Delivery.closed?(Connections.get(fresh_id).delivery)
    recovered = drain(fresh)

    assert [{:event, "chat", %{"text" => "current"}, _}] =
             Enum.filter(recovered, &match?({:event, "chat", _, _}, &1))
  end

  test "socket emits an explicit resync, then ignores queued progress and terminal before disconnect" do
    state = %Connection{conn_id: "overflow", connected: true, event_seq: 7, state_version: %{}}

    assert {:push, {:text, frame}, state} =
             Connection.handle_info({:stream_resync, :overflow}, state)

    assert %{
             "type" => "event",
             "event" => "stream.resync",
             "payload" => %{"reason" => "overflow"},
             "seq" => 8
           } = Jason.decode!(frame)

    assert state.resync_required

    assert {:ok, ^state} =
             Connection.handle_info({:event, "agent", %{"type" => "run_completed"}, %{}}, state)

    assert {:ok, ^state} =
             Connection.handle_info(
               {:event, "exec.approval.requested", %{"approvalId" => "stale"}},
               state
             )

    assert_receive :stream_overflow_disconnect
    assert {:stop, :normal, ^state} = Connection.handle_info(:stream_overflow_disconnect, state)
  end

  test "disconnected socket death removes presence resources and permanently fences its delivery" do
    socket = frozen_consumer()
    conn_id = "dead-pressure-#{System.unique_integer([:positive])}"

    :ok =
      Connections.register(conn_id, %{
        role: :operator,
        auth: @operator_auth,
        client_id: "dead",
        pid: socket
      })

    %{delivery: delivery} = Connections.get(conn_id)
    admitter_ref = Process.monitor(delivery.admitter)
    ref = Process.monitor(socket)
    Process.exit(socket, :kill)
    assert_receive {:DOWN, ^ref, :process, ^socket, :killed}
    assert_receive {:DOWN, ^admitter_ref, :process, _admitter, :normal}
    assert Connections.get(conn_id) == nil
    assert Delivery.closed?(delivery)
  end

  defp frozen_consumer do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :drain -> send(parent, {:drained, self(), collect([])})
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp drain(pid) do
    send(pid, :drain)
    assert_receive {:drained, ^pid, messages}, 1000
    messages
  end

  defp collect(acc) do
    receive do
      message -> collect([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
