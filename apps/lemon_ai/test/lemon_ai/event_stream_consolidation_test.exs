defmodule LemonAi.EventStreamConsolidationTest do
  use ExUnit.Case, async: true

  alias LemonAi.EventStream
  alias LemonAi.Types.AssistantMessage

  @tag timeout: 15_000
  test "a queued push survives a suspended stream beyond the legacy five-second call timeout" do
    stream = start_stream()
    parent = self()
    token = make_ref()
    event = {:heartbeat, token}
    :ok = :sys.suspend(stream)

    {producer, monitor} =
      spawn_monitor(fn -> send(parent, {token, EventStream.push(stream, event)}) end)

    on_exit(fn -> Process.exit(producer, :kill) end)

    try do
      await(fn ->
        {:messages, messages} = Process.info(stream, :messages)

        Enum.any?(messages, fn
          {:"$gen_call", {^producer, _tag}, {:push, ^event}} -> true
          _ -> false
        end)
      end)

      # Start the bounded wait only after the call is actually queued. A legacy
      # GenServer.call/2 exits here; producer startup cannot mask the regression.
      refute_receive {:DOWN, ^monitor, :process, ^producer, _reason}, 5_100
      refute_receive {^token, _result}, 0
      assert Process.alive?(producer)
    after
      :ok = :sys.resume(stream)
    end

    assert_receive {^token, :ok}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 1_000
    assert [^event] = stream |> EventStream.events() |> Enum.take(1)
  end

  test "owner death shuts down the attached task and resolves registered consumers" do
    owner = waiting_process()
    worker = waiting_process()
    stream = start_stream(owner: owner)
    stream_monitor = Process.monitor(stream)
    worker_monitor = Process.monitor(worker)
    :ok = EventStream.attach_task(stream, worker)
    assert :sys.get_state(stream).task_pid == worker
    {:ok, subscription} = EventStream.subscribe_result(stream)
    reader = Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)
    waiter = Task.async(fn -> EventStream.result(stream) end)
    await_consumers(stream, 2)

    send(owner, :stop)

    assert Task.await(waiter, 1_000) == {:error, {:canceled, :owner_down}}
    assert Task.await(reader, 1_000) == [{:canceled, :owner_down}]

    assert_receive {:event_stream_result, ^subscription, {:error, {:canceled, :owner_down}}},
                   1_000

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1_000
    assert_receive {:DOWN, ^stream_monitor, :process, ^stream, :normal}, 1_000
  end

  for {option, reason} <- [idle_timeout: :stream_idle_timeout, timeout: :timeout] do
    test "#{option} resolves terminal results and shuts down the attached task" do
      stream = start_stream()
      worker = waiting_process()
      worker_monitor = Process.monitor(worker)
      stream_monitor = Process.monitor(stream)
      :ok = EventStream.attach_task(stream, worker)
      {:ok, subscription} = EventStream.subscribe_result(stream)
      reader = Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)
      waiter = Task.async(fn -> EventStream.result(stream) end)
      await_consumers(stream, 2)

      # Arm a real timer only after all consumers are registered, rather than
      # racing a short timeout against task startup or injecting a fake expiry.
      assert :ok = EventStream.configure_timeouts(stream, [{unquote(option), 0}])

      assert Task.await(waiter, 1_000) == {:error, {:canceled, unquote(reason)}}
      assert Task.await(reader, 1_000) == [{:canceled, unquote(reason)}]

      assert_receive {:event_stream_result, ^subscription,
                      {:error, {:canceled, unquote(reason)}}},
                     1_000

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1_000
      assert_receive {:DOWN, ^stream_monitor, :process, ^stream, :normal}, 1_000
    end
  end

  test "activity resets only the idle timer and completion disarms both timers" do
    stream = start_stream(timeout: 60_000, idle_timeout: 60_000)
    initial = :sys.get_state(stream)
    assert :ok = EventStream.push(stream, :heartbeat)
    active = :sys.get_state(stream)
    assert active.timeout_ref == initial.timeout_ref
    refute active.idle_timeout_ref == initial.idle_timeout_ref
    assert Process.read_timer(initial.idle_timeout_ref) == false

    send(stream, {:timeout, initial.idle_timeout_ref, :stream_idle_timeout})
    assert :ok = EventStream.push(stream, :still_active)
    active = :sys.get_state(stream)
    message = %AssistantMessage{stop_reason: :stop}
    :ok = EventStream.complete(stream, message)
    assert EventStream.result(stream, 1_000) == {:ok, message}
    assert Process.read_timer(active.timeout_ref) == false
    assert Process.read_timer(active.idle_timeout_ref) == false

    send(stream, {:timeout, active.idle_timeout_ref, :stream_idle_timeout})
    send(stream, {:timeout, active.timeout_ref, :stream_timeout})
    assert EventStream.result(stream, 1_000) == {:ok, message}

    assert Enum.to_list(EventStream.events(stream)) == [
             :heartbeat,
             :still_active,
             {:done, :stop, message}
           ]
  end

  test "completion retains assistant, map and agent-list result shapes" do
    message = %AssistantMessage{stop_reason: :stop}

    for {result, terminal} <- [
          {message, {:done, :stop, message}},
          {%{"stop_reason" => "length"}, {:done, "length", %{"stop_reason" => "length"}}},
          {[message], {:agent_end, [message]}},
          {[], {:agent_end, []}}
        ] do
      stream = start_stream()
      {:ok, subscription} = EventStream.subscribe_result(stream)
      assert :ok = EventStream.push(stream, :accepted)
      assert :ok = EventStream.complete(stream, result)
      assert EventStream.result(stream, 1_000) == {:ok, result}
      assert Enum.to_list(EventStream.events(stream)) == [:accepted, terminal]
      assert EventStream.result(stream, 1_000) == {:ok, result}
      assert_receive {:event_stream_result, ^subscription, {:ok, ^result}}, 1_000
      refute_receive {:event_stream_result, ^subscription, _}, 0
    end
  end

  test "assistant and agent errors preserve their distinct terminal results" do
    message = %AssistantMessage{
      stop_reason: :error,
      error_message: "provider unavailable",
      error_details: %{category: :transient}
    }

    stream = start_stream()
    assert :ok = EventStream.error(stream, message)
    assert EventStream.result(stream, 1_000) == {:error, message}
    assert Enum.to_list(EventStream.events(stream)) == [{:error, :error, message}]

    stream = start_stream()
    partial = %{messages: []}
    assert :ok = EventStream.error(stream, :tool_failed, partial)
    assert EventStream.result(stream, 1_000) == {:error, :tool_failed, partial}
    assert Enum.to_list(EventStream.events(stream)) == [{:error, :tool_failed, partial}]
  end

  test "overflow is explicit and cannot discard the completion terminal" do
    stream = start_stream(max_queue: 1, drop_strategy: :error)
    message = %AssistantMessage{stop_reason: :stop}
    assert :ok = EventStream.push(stream, :accepted)
    assert {:error, :overflow} = EventStream.push(stream, :rejected)
    assert :ok = EventStream.complete(stream, message)
    assert EventStream.result(stream, 1_000) == {:ok, message}
    assert Enum.to_list(EventStream.events(stream)) == [{:done, :stop, message}]
  end

  defp start_stream(opts \\ []) do
    {:ok, stream} =
      EventStream.start_link(Keyword.merge([timeout: :infinity, idle_timeout: :infinity], opts))

    stream
  end

  defp waiting_process do
    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp await_consumers(stream, result_count) do
    await(fn ->
      state = :sys.get_state(stream)
      :queue.len(state.take_waiters) == 1 and :queue.len(state.result_waiters) == result_count
    end)
  end

  defp await(predicate) do
    await(predicate, System.monotonic_time(:millisecond) + 1_000)
  end

  defp await(predicate, deadline) do
    unless predicate.() do
      assert System.monotonic_time(:millisecond) < deadline,
             "stream did not reach the expected state"

      receive do
      after
        1 -> await(predicate, deadline)
      end
    end
  end
end
