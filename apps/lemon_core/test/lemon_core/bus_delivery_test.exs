defmodule LemonCore.Bus.DeliveryTest do
  use ExUnit.Case, async: true

  alias LemonCore.Bus.Delivery
  alias LemonCore.Event

  test "a stopped consumer admits eight small events and one recovery marker, not the burst" do
    pid = frozen_consumer()
    delivery = Delivery.new(pid, max_queue: 8, max_bytes: 256)
    payload = String.duplicate("x", 64)

    for n <- 1..2000, do: Delivery.send(delivery, {:progress, n, payload})

    assert {:message_queue_len, 9} = Process.info(pid, :message_queue_len)
    assert {:memory, bytes} = Process.info(pid, :memory)
    assert bytes < 256_000
    assert Delivery.closed?(delivery)
    assert {:error, :closed} = Delivery.send(delivery, {:terminal, :completed})
    assert :ok = Delivery.terminal(delivery, {:owner_terminal, :completed})
    assert :ok = Delivery.terminal(delivery, {:owner_terminal, :running})
    assert {:message_queue_len, 10} = Process.info(pid, :message_queue_len)

    messages = drain(pid)

    retained_bytes =
      Enum.reduce(messages, 0, fn message, total -> total + :erlang.external_size(message) end)

    control_allowance = :erlang.external_size({:stream_resync, :overflow}) + 1024
    assert retained_bytes <= 8 * 256 + control_allowance
    assert Enum.count(messages, &match?({:progress, _, _}, &1)) == 8
    assert Enum.count(messages, &(&1 == {:stream_resync, :overflow})) == 1
    assert List.last(messages) == {:owner_terminal, :completed}
  end

  test "concurrent publishers fail closed without waiting, spawning fanout tasks, or reviving delivery" do
    pid = frozen_consumer()
    delivery = Delivery.new(pid, max_queue: 8, max_bytes: 256)
    parent = self()

    publishers =
      for n <- 1..8 do
        spawn_monitor(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> for i <- 1..100, do: Delivery.send(delivery, {:progress, n, i})
          end
        end)
      end

    for {publisher, _ref} <- publishers, do: assert_receive({:ready, ^publisher})
    for {publisher, _ref} <- publishers, do: send(publisher, :go)

    for {publisher, ref} <- publishers,
        do: assert_receive({:DOWN, ^ref, :process, ^publisher, :normal})

    assert {:message_queue_len, count} = Process.info(pid, :message_queue_len)
    assert count <= 9
    assert Delivery.closed?(delivery)
    messages = drain(pid)
    assert Enum.count(messages, &(&1 == {:stream_resync, :overflow})) == 1
    assert {:error, :closed} = Delivery.send(delivery, {:progress, :late})
  end

  test "oversized messages never enter the consumer mailbox and no payload is copied into recovery" do
    pid = frozen_consumer()
    delivery = Delivery.new(pid, max_queue: 8, max_bytes: 128)

    assert {:error, :overflow} =
             Delivery.send(delivery, {:private_output, String.duplicate("secret", 100)})

    assert drain(pid) == [{:stream_resync, :overflow}]
  end

  test "small sub-binaries cannot pin oversized backing buffers in data or control slots" do
    pid = frozen_consumer()
    backing = :binary.copy("x", 16_384)
    slice = binary_part(backing, 0, 256)
    assert byte_size(slice) == 256
    assert :binary.referenced_byte_size(slice) == byte_size(backing)
    message = {:progress, %{payload: [slice]}}
    assert :erlang.external_size(message) < 1024
    delivery = Delivery.new(pid, max_bytes: 1024)
    assert {:error, :overflow} = Delivery.send(delivery, message)
    assert :ok = Delivery.terminal(delivery, {:terminal, slice})
    assert drain(pid) == [{:stream_resync, :overflow}]
    assert_raise ArgumentError, fn -> Delivery.new(pid, overflow_message: slice) end
  end

  test "tagged admission traverses nested core event structs and bounded sub-binaries" do
    pid = frozen_consumer()
    backing = :binary.copy("x", 2048)
    slice = binary_part(backing, 0, 256)
    assert :binary.referenced_byte_size(slice) == byte_size(backing)
    child = Event.new(:tool_execution_update, %{content: [slice]})

    event =
      Event.new(
        :run_progress,
        %{nested: [{child, %{child => [child]}}]},
        %{run_id: "nested-struct-run", context: child}
      )

    delivery = Delivery.new(pid, tagged: true, max_bytes: 16_384)
    assert :ok = Delivery.send(delivery, event)
    refute Delivery.closed?(delivery)
    assert [{:lemon_bus_delivery, gate, ^event}] = drain(pid)
    assert Delivery.matches?(delivery, gate)
  end

  test "nested core event structs cannot hide oversized backing in map keys or values" do
    backing = :binary.copy("x", 65_536)
    slice = binary_part(backing, 0, 256)
    assert :binary.referenced_byte_size(slice) == byte_size(backing)
    child = Event.new(:tool_execution_update, %{content: [slice]})

    for payload <- [%{nested: [child]}, %{child => :metadata}] do
      pid = frozen_consumer()
      event = Event.new(:run_progress, payload, %{run_id: "oversized-struct-run"})
      assert :erlang.external_size(event) < 4096
      delivery = Delivery.new(pid, tagged: true, max_bytes: 4096)
      assert {:error, :overflow} = Delivery.send(delivery, event)
      assert :ok = Delivery.terminal(delivery, event)
      assert [{:lemon_bus_delivery, gate, {:stream_resync, :overflow}}] = drain(pid)
      assert Delivery.matches?(delivery, gate)
      assert Delivery.closed?(delivery)
    end
  end

  test "dead consumers close admission and require no cleanup worker" do
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    delivery = Delivery.new(pid)
    assert {:error, :closed} = Delivery.send(delivery, :event)
    assert Delivery.closed?(delivery)
  end

  test "tagged admission lets a recovered consumer reject old in-flight data and recovery markers" do
    pid = frozen_consumer()
    old = Delivery.new(pid, tagged: true)
    assert :ok = Delivery.send(old, :old_progress)
    assert {:error, :overflow} = Delivery.resync(old)
    fresh = Delivery.new(pid, tagged: true)
    assert :ok = Delivery.send(fresh, :current_progress)

    messages = drain(pid)

    assert [
             {:lemon_bus_delivery, old_gate, :old_progress},
             {:lemon_bus_delivery, old_gate, {:stream_resync, :overflow}},
             {:lemon_bus_delivery, fresh_gate, :current_progress}
           ] = messages

    refute Delivery.matches?(fresh, old_gate)
    assert Delivery.matches?(fresh, fresh_gate)
    refute Delivery.matches?(nil, fresh_gate)
  end

  test "tagged byte admission accounts for envelope overhead and bounds recovery controls" do
    pid = frozen_consumer()
    delivery = Delivery.new(pid, tagged: true, max_bytes: :erlang.external_size(:small))
    assert {:error, :overflow} = Delivery.send(delivery, :small)
    assert [{:lemon_bus_delivery, gate, {:stream_resync, :overflow}}] = drain(pid)
    assert Delivery.matches?(delivery, gate)

    assert_raise ArgumentError, fn ->
      Delivery.new(self(), overflow_message: String.duplicate("x", 1024))
    end
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
    assert_receive {:drained, ^pid, messages}
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
