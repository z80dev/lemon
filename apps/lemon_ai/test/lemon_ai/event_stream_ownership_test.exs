defmodule LemonAi.EventStreamOwnershipTest do
  use ExUnit.Case, async: true

  alias LemonAi.EventStream
  alias LemonAi.Types.AssistantMessage

  describe "owner and deadline teardown" do
    for {exit_reason, cancel_reason} <- [
          {:normal, :owner_down},
          {:crash, :owner_down},
          {:shutdown, :shutdown},
          {{:shutdown, :supervised}, :shutdown}
        ] do
      @tag :concurrency
      test "owner exit #{inspect(exit_reason)} shuts down the worker and resolves registered consumers" do
        owner = waiting_process()
        {stream, stream_monitor, worker, worker_monitor} = with_worker(owner: owner)
        consumers = waiting_consumers(stream)

        case unquote(Macro.escape(exit_reason)) do
          :normal -> send(owner, :stop)
          reason -> Process.exit(owner, reason)
        end

        assert_canceled(consumers, unquote(cancel_reason))
        assert_shutdown(stream, stream_monitor, worker, worker_monitor)
      end
    end

    for {option, reason} <- [idle_timeout: :stream_idle_timeout, timeout: :timeout] do
      test "#{option} resolves waiting consumers and shuts down the attached worker" do
        {stream, stream_monitor, worker, worker_monitor} = with_worker()
        consumers = waiting_consumers(stream)
        # Arm a real deadline after all consumers are registered.
        assert :ok = EventStream.configure_timeouts(stream, [{unquote(option), 0}])
        assert_canceled(consumers, unquote(reason))
        assert_shutdown(stream, stream_monitor, worker, worker_monitor)
      end
    end

    for cause <- [:owner_down, :timeout] do
      @tag :concurrency
      test "#{cause} frees a buffered stream even without an event reader" do
        owner = waiting_process()

        {stream, stream_monitor, worker, worker_monitor} =
          with_worker(owner: owner, event_format: :agent)

        assert :ok = EventStream.push(stream, :abandoned_event)
        {:ok, subscription} = EventStream.subscribe_result(stream)

        case unquote(cause) do
          :owner_down -> send(owner, :stop)
          :timeout -> assert :ok = EventStream.configure_timeouts(stream, timeout: 0)
        end

        reason = unquote(cause)

        assert_receive {:event_stream_result, ^subscription, {:error, {:canceled, ^reason}}},
                       1_000

        assert_shutdown(stream, stream_monitor, worker, worker_monitor)
      end
    end

    for start <- [:start, :start_link] do
      test "#{start} defaults ownership to its caller, releasing an undrained cancellation when the caller dies" do
        parent = self()

        owner =
          spawn(fn ->
            stream = start_stream([event_format: :agent], unquote(start))
            :ok = EventStream.push(stream, :unconsumed)
            :ok = EventStream.cancel(stream)
            {:error, {:canceled, :canceled}} = EventStream.result(stream)
            send(parent, {:ready, stream})
            receive do: (:stop -> :ok)
          end)

        on_exit(fn -> Process.exit(owner, :kill) end)
        assert_receive {:ready, stream}, 1_000
        monitor = Process.monitor(stream)
        assert Process.alive?(stream)
        send(owner, :stop)
        assert_receive {:DOWN, ^monitor, :process, ^stream, :normal}, 1_000
      end
    end

    test "an unlinked stream with an explicit owner outlives its launcher" do
      owner = self()

      {launcher, monitor} =
        spawn_monitor(fn ->
          send(owner, {:stream, start_stream([owner: owner], :start)})
        end)

      assert_receive {:stream, stream}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^launcher, :normal}, 1_000
      assert :ok = EventStream.push(stream, :still_open)
      assert EventStream.result(stream, 0) == {:error, :timeout}
      assert Enum.take(EventStream.events(stream), 1) == [:still_open]
    end

    test "linked-parent shutdown tears down a worker even when the owner is still alive" do
      owner = self()
      worker = waiting_process()
      worker_monitor = Process.monitor(worker)

      launcher =
        spawn(fn ->
          stream = start_stream(owner: owner)
          :ok = EventStream.attach_task(stream, worker)
          {:ok, subscription} = EventStream.subscribe_result(stream, owner)
          send(owner, {:ready, stream, subscription})
          receive do: (:stop -> :ok)
        end)

      on_exit(fn -> Process.exit(launcher, :kill) end)
      assert_receive {:ready, stream, subscription}, 1_000
      stream_monitor = Process.monitor(stream)
      Process.exit(launcher, :shutdown)

      assert_receive {:event_stream_result, ^subscription, {:error, {:canceled, :shutdown}}},
                     1_000

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1_000
      assert_receive {:DOWN, ^stream_monitor, :process, ^stream, :shutdown}, 1_000
    end

    test "activity resets only the idle timer and completion disarms both timers" do
      stream = start_stream(timeout: 60_000, idle_timeout: 60_000)
      initial = :sys.get_state(stream)
      events = [{:thinking_delta, 0, "thought"}, {:text_delta, 0, "text"}, :heartbeat]

      for event <- events do
        idle_ref = :sys.get_state(stream).idle_timeout_ref
        assert :ok = EventStream.push(stream, event)
        active = :sys.get_state(stream)
        assert active.timeout_ref == initial.timeout_ref
        refute active.idle_timeout_ref == idle_ref
        assert Process.read_timer(idle_ref) == false
        send(stream, {:timeout, idle_ref, :stream_idle_timeout})
      end

      active = :sys.get_state(stream)
      message = %AssistantMessage{stop_reason: :stop}
      assert :ok = EventStream.complete(stream, message)
      assert EventStream.result(stream, 1_000) == {:ok, message}
      assert Process.read_timer(active.timeout_ref) == false
      assert Process.read_timer(active.idle_timeout_ref) == false

      send(stream, {:timeout, active.idle_timeout_ref, :stream_idle_timeout})
      send(stream, {:timeout, active.timeout_ref, :stream_timeout})
      assert EventStream.result(stream, 1_000) == {:ok, message}
      assert Enum.to_list(EventStream.events(stream)) == events ++ [{:done, :stop, message}]
    end

    test "infinite hard and idle deadlines leave the stream open" do
      stream = start_stream()
      assert %{timeout_ref: nil, idle_timeout_ref: nil} = :sys.get_state(stream)
      assert :ok = EventStream.push_async(stream, :still_open)
      assert EventStream.result(stream, 0) == {:error, :timeout}
      assert %{timeout_ref: nil, idle_timeout_ref: nil} = :sys.get_state(stream)
      assert Enum.take(EventStream.events(stream), 1) == [:still_open]
    end
  end

  describe "explicit cancellation" do
    @tag :concurrency
    test "provider cancel resolves all waiting consumers with one terminal and tears down the worker" do
      {stream, stream_monitor, worker, worker_monitor} = with_worker()
      consumers = waiting_consumers(stream)
      assert :ok = EventStream.cancel(stream)
      assert_canceled(consumers, :canceled)
      assert_shutdown(stream, stream_monitor, worker, worker_monitor)
      assert EventStream.push(stream, :late) == {:error, :canceled}
    end

    for strategy <- [:error, :drop_oldest, :drop_newest] do
      @tag :concurrency
      test "agent cancellation drains every accepted event before one terminal with #{strategy}" do
        stream =
          start_stream(
            event_format: :agent,
            max_queue: 2,
            drop_strategy: unquote(strategy),
            timeout: 60_000
          )

        monitor = Process.monitor(stream)
        hard_timeout = :sys.get_state(stream).timeout_ref
        accepted = [{:message_end, :assistant}, {:message_end, :tool_result}]

        for event <- accepted, do: assert(:ok = EventStream.push(stream, event))
        assert :ok = EventStream.cancel(stream, :drain)
        assert EventStream.result(stream, 1_000) == {:error, {:canceled, :drain}}
        assert Process.read_timer(hard_timeout) == false
        send(stream, {:timeout, hard_timeout, :stream_timeout})

        assert :ok = EventStream.cancel(stream, :repeat)
        assert :ok = EventStream.complete(stream, [:late_completion])
        assert :ok = EventStream.error(stream, :late_error, nil)
        assert :ok = EventStream.push_async(stream, :late_async)
        assert EventStream.push(stream, :late) == {:error, :canceled}
        assert EventStream.result(stream, 1_000) == {:error, {:canceled, :drain}}
        assert EventStream.stats(stream) == %{queue_size: 3, max_queue: 2, dropped: 0}

        assert Enum.take(EventStream.events(stream), 2) == accepted
        assert Process.alive?(stream)
        assert Enum.to_list(EventStream.events(stream)) == [{:canceled, :drain}]
        assert_receive {:DOWN, ^monitor, :process, ^stream, :normal}, 1_000
        assert EventStream.push(stream, :after_drain) == {:error, :canceled}
      end
    end

    test "late cancellation keeps agent terminals and never calls the cancellation handler" do
      parent = self()

      for {finish, result, terminal} <- [
            {fn stream -> EventStream.complete(stream, []) end, {:ok, []}, {:agent_end, []}},
            {fn stream -> EventStream.error(stream, :failed, %{partial: true}) end,
             {:error, :failed, %{partial: true}}, {:error, :failed, %{partial: true}}}
          ] do
        stream =
          start_stream(
            event_format: :agent,
            on_cancel: fn -> send(parent, :unexpected_cancel) end
          )

        assert :ok = EventStream.push(stream, :accepted)
        assert :ok = finish.(stream)
        assert :ok = EventStream.cancel(stream, :too_late)
        assert EventStream.result(stream, 1_000) == result
        assert Enum.to_list(EventStream.events(stream)) == [:accepted, terminal]
        refute_receive :unexpected_cancel, 0
      end
    end

    test "late cancellation releases completed provider streams and their attached workers" do
      for {finish, result_tag, message} <- [
            {&EventStream.complete/2, :ok, %AssistantMessage{stop_reason: :stop}},
            {&EventStream.error/2, :error,
             %AssistantMessage{stop_reason: :error, error_details: %{category: :transient}}}
          ] do
        {stream, stream_monitor, worker, worker_monitor} = with_worker()
        {:ok, subscription} = EventStream.subscribe_result(stream)
        result = {result_tag, message}
        assert :ok = EventStream.push(stream, :accepted)
        assert :ok = finish.(stream, message)
        assert EventStream.result(stream, 1_000) == result
        assert EventStream.stats(stream).queue_size == 2
        assert_receive {:event_stream_result, ^subscription, ^result}, 1_000
        assert :ok = EventStream.cancel(stream, :completion_collected)
        assert_shutdown(stream, stream_monitor, worker, worker_monitor)
        refute_receive {:event_stream_result, ^subscription, _}, 0
      end
    end
  end

  @tag :concurrency
  test "replacing an attached worker leaves the old one alone and removes its monitor" do
    stream = start_stream()
    first = waiting_process()
    second = waiting_process()
    second_monitor = Process.monitor(second)
    assert :ok = EventStream.attach_task(stream, first)
    _ = EventStream.stats(stream)
    assert {:monitors, monitors} = Process.info(stream, :monitors)
    assert {:process, first} in monitors
    assert :ok = EventStream.attach_task(stream, second)
    _ = EventStream.stats(stream)
    assert {:monitors, monitors} = Process.info(stream, :monitors)
    refute {:process, first} in monitors
    assert {:process, second} in monitors
    assert :ok = EventStream.cancel(stream)
    assert_receive {:DOWN, ^second_monitor, :process, ^second, :shutdown}, 1_000
    assert Process.alive?(first)
  end

  defp start_stream(opts \\ [], start \\ :start_link) do
    {:ok, stream} =
      apply(EventStream, start, [
        Keyword.merge([timeout: :infinity, idle_timeout: :infinity], opts)
      ])

    stream
  end

  defp with_worker(opts \\ []) do
    stream = start_stream(opts)
    worker = waiting_process()
    worker_monitor = Process.monitor(worker)
    assert :ok = EventStream.attach_task(stream, worker)
    {stream, Process.monitor(stream), worker, worker_monitor}
  end

  defp waiting_process do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp waiting_consumers(stream) do
    {:ok, subscription} = EventStream.subscribe_result(stream)
    readers = for _ <- 1..2, do: Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)
    waiters = for _ <- 1..2, do: Task.async(fn -> EventStream.result(stream) end)
    await_consumers(stream, System.monotonic_time(:millisecond) + 1_000)
    {subscription, readers, waiters}
  end

  defp await_consumers(stream, deadline) do
    state = :sys.get_state(stream)

    unless :queue.len(state.take_waiters) == 2 and :queue.len(state.result_waiters) == 3 do
      assert System.monotonic_time(:millisecond) < deadline, "stream consumers did not register"
      Process.sleep(1)
      await_consumers(stream, deadline)
    end
  end

  defp assert_canceled({subscription, readers, waiters}, reason) do
    result = {:error, {:canceled, reason}}
    assert Task.await_many(waiters, 1_000) == [result, result]
    assert Task.await_many(readers, 1_000) |> List.flatten() == [{:canceled, reason}]
    assert_receive {:event_stream_result, ^subscription, ^result}, 1_000
    refute_receive {:event_stream_result, ^subscription, _}, 0
  end

  defp assert_shutdown(stream, stream_monitor, worker, worker_monitor) do
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1_000
    assert_receive {:DOWN, ^stream_monitor, :process, ^stream, :normal}, 1_000
  end
end
