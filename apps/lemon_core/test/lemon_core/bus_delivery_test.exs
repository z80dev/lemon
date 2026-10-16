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

  test "concurrent queue pressure stays bounded and never revives fenced delivery" do
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

  test "dead consumers close admission and release the admission process" do
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    delivery = Delivery.new(pid)
    admitter_ref = Process.monitor(delivery.admitter)
    assert_receive {:DOWN, ^admitter_ref, :process, _admitter, reason}
    assert reason in [:normal, :noproc]
    assert Delivery.closed?(delivery)
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

  test "pending admission capacity is bounded and real overflow releases every publisher" do
    consumer = frozen_consumer()
    delivery = Delivery.new(consumer, max_queue: 2)
    true = :erlang.suspend_process(delivery.admitter)

    publishers =
      try do
        publishers = for n <- 1..2, do: queued_publisher(delivery, {:pending, n})
        assert {:message_queue_len, 2} = Process.info(delivery.admitter, :message_queue_len)
        assert {:error, :overflow} = Delivery.send(delivery, :excess)
        assert {:message_queue_len, 3} = Process.info(delivery.admitter, :message_queue_len)
        assert :ok = Delivery.terminal(delivery, :terminal)
        assert :ok = Delivery.terminal(delivery, :duplicate_terminal)
        publishers
      after
        :erlang.resume_process(delivery.admitter)
      end

    for {pid, ref} <- publishers do
      assert_receive {:published, ^pid, {:error, :closed}}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    assert drain(consumer) == [{:stream_resync, :overflow}, :terminal]
  end

  test "admission process death resyncs rather than silently losing a queued broadcast" do
    consumer = frozen_consumer()
    delivery = Delivery.new(consumer)
    true = :erlang.suspend_process(delivery.admitter)
    {publisher, ref} = queued_publisher(delivery, :pending)
    Process.exit(delivery.admitter, :kill)
    assert_receive {:published, ^publisher, {:error, :overflow}}
    assert_receive {:DOWN, ^ref, :process, ^publisher, :normal}
    assert Delivery.closed?(delivery)
    assert drain(consumer) == [{:stream_resync, :overflow}]
  end

  test "an unavailable admission process has a finite wait and emits one recovery marker" do
    consumer = frozen_consumer()
    delivery = Delivery.new(consumer)
    true = :erlang.suspend_process(delivery.admitter)

    try do
      {publisher, ref} = queued_publisher(delivery, :pending)
      assert_receive {:published, ^publisher, {:error, :overflow}}, 6000
      assert_receive {:DOWN, ^ref, :process, ^publisher, :normal}
      assert Delivery.closed?(delivery)
      assert {:error, :closed} = Delivery.send(delivery, :late)
      assert drain(consumer) == [{:stream_resync, :overflow}]
    after
      :erlang.resume_process(delivery.admitter)
    end
  end

  test "a consumer can publish to itself without waiting for its own receive loop" do
    delivery = Delivery.new(self(), max_queue: 2)
    assert :ok = Delivery.send(delivery, :first)
    assert_receive :first
    assert :ok = Delivery.send(delivery, :second)
    assert_receive :second
    ref = Process.monitor(delivery.admitter)
    assert :ok = Delivery.close(delivery)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
  end

  test "a dead queued publisher releases capacity without blocking a live publisher" do
    consumer = frozen_consumer()
    delivery = Delivery.new(consumer, max_queue: 2)
    true = :erlang.suspend_process(delivery.admitter)

    {live, live_ref} =
      try do
        {dead, dead_ref} = queued_publisher(delivery, :dead)
        Process.exit(dead, :kill)
        assert_receive {:DOWN, ^dead_ref, :process, ^dead, :killed}
        queued_publisher(delivery, :live)
      after
        :erlang.resume_process(delivery.admitter)
      end

    assert_receive {:published, ^live, :ok}
    assert_receive {:DOWN, ^live_ref, :process, ^live, :normal}
    assert :ok = Delivery.send(delivery, :next)
    refute Delivery.closed?(delivery)
    assert drain(consumer) == [:live, :next]
  end

  test "close releases queued publishers and preserves one terminal after accepted progress" do
    consumer = frozen_consumer()
    delivery = Delivery.new(consumer, max_queue: 2)
    assert :ok = Delivery.send(delivery, :accepted)
    true = :erlang.suspend_process(delivery.admitter)

    {publisher, ref} =
      try do
        publisher = queued_publisher(delivery, :not_admitted)
        assert :ok = Delivery.close(delivery)
        assert :ok = Delivery.terminal(delivery, :terminal)
        assert :ok = Delivery.terminal(delivery, :duplicate_terminal)
        publisher
      after
        :erlang.resume_process(delivery.admitter)
      end

    assert_receive {:published, ^publisher, {:error, :closed}}
    assert_receive {:DOWN, ^ref, :process, ^publisher, :normal}
    assert drain(consumer) == [:accepted, :terminal]
  end

  test "creator death fences the handle and releases its admission process" do
    consumer = frozen_consumer()
    parent = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        send(parent, {:delivery, Delivery.new(consumer)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:delivery, delivery}
    ref = Process.monitor(delivery.admitter)
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    assert Delivery.closed?(delivery)
    assert {:error, :closed} = Delivery.send(delivery, :late)
    assert drain(consumer) == []
  end

  defp queued_publisher(delivery, message) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :publish -> send(parent, {:published, self(), Delivery.send(delivery, message)})
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    :erlang.trace(pid, true, [:send, {:tracer, parent}])
    send(pid, :publish)
    admitter = delivery.admitter
    assert_receive {:trace, ^pid, :send, {:admit, ^pid, _ref, ^message}, ^admitter}
    :erlang.trace(pid, false, [:send])
    {pid, ref}
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
