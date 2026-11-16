defmodule LemonAgent.EventStreamConsolidationTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{AbortSignal, EventStream}
  alias LemonAi.EventStream, as: AiStream
  alias LemonAi.Types.AssistantMessage

  @tag timeout: 15_000
  test "the published facade also waits beyond five seconds for a suspended stream" do
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

      refute_receive {:DOWN, ^monitor, :process, ^producer, _reason}, 5_100
      refute_receive {^token, _result}, 0
      assert Process.alive?(producer)
    after
      :ok = :sys.resume(stream)
    end

    assert_receive {^token, :ok}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^producer, :normal}, 1_000
    assert [^event] = stream |> AiStream.events() |> Enum.take(1)
  end

  for {writer, reader} <- [{EventStream, AiStream}, {AiStream, EventStream}] do
    @writer writer
    @reader reader

    test "#{inspect(writer)} completion is readable through #{inspect(reader)}" do
      message = %AssistantMessage{stop_reason: :stop}

      for {result, terminal} <- [
            {[message], {:agent_end, [message]}},
            {message, {:done, :stop, message}}
          ] do
        {:ok, stream} = @writer.start_link(timeout: :infinity, idle_timeout: :infinity)
        {:ok, subscription} = AiStream.subscribe_result(stream)
        assert :ok = @writer.push(stream, :accepted)
        assert :ok = @writer.complete(stream, result)
        assert @reader.result(stream, 1_000) == {:ok, result}
        assert Enum.to_list(@reader.events(stream)) == [:accepted, terminal]
        assert @reader.result(stream, 1_000) == {:ok, result}
        assert_receive {:event_stream_result, ^subscription, {:ok, ^result}}, 1_000
      end
    end
  end

  test "the agent facade preserves error arities and explicit overflow feedback" do
    stream = start_stream(max_queue: 1, drop_strategy: :error)
    assert :ok = EventStream.push(stream, :accepted)
    assert {:error, :overflow} = EventStream.push(stream, :rejected)
    partial = %{messages: []}
    assert :ok = EventStream.error(stream, :tool_failed, partial)
    assert AiStream.result(stream, 1_000) == {:error, :tool_failed, partial}
    assert Enum.to_list(AiStream.events(stream)) == [{:error, :tool_failed, partial}]

    stream = start_stream()
    assert :ok = EventStream.error(stream, "agent failure")
    assert AiStream.result(stream, 1_000) == {:error, "agent failure", nil}
    assert Enum.to_list(AiStream.events(stream)) == [{:error, "agent failure", nil}]
  end

  test "owner death through the facade cancels the task and resolves both consumers" do
    owner = waiting_process()
    worker = waiting_process()
    stream = start_stream(owner: owner)
    stream_monitor = Process.monitor(stream)
    worker_monitor = Process.monitor(worker)
    :ok = EventStream.attach_task(stream, worker)
    {:ok, subscription} = AiStream.subscribe_result(stream)
    reader = Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)
    waiter = Task.async(fn -> EventStream.result(stream) end)
    await_consumers(stream)
    assert :sys.get_state(stream).task_pid == worker

    send(owner, :stop)

    assert Task.await(waiter, 1_000) == {:error, {:canceled, :owner_down}}
    assert Task.await(reader, 1_000) == [{:canceled, :owner_down}]

    assert_receive {:event_stream_result, ^subscription, {:error, {:canceled, :owner_down}}},
                   1_000

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1_000
    assert_receive {:DOWN, ^stream_monitor, :process, ^stream, :normal}, 1_000
  end

  for {option, reason} <- [idle_timeout: :stream_idle_timeout, timeout: :timeout] do
    test "the facade retains #{option} cancellation and terminal results" do
      stream = start_stream()
      worker = waiting_process()
      worker_monitor = Process.monitor(worker)
      stream_monitor = Process.monitor(stream)
      :ok = EventStream.attach_task(stream, worker)
      {:ok, subscription} = AiStream.subscribe_result(stream)
      reader = Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)
      waiter = Task.async(fn -> EventStream.result(stream) end)
      await_consumers(stream)
      assert :ok = AiStream.configure_timeouts(stream, [{unquote(option), 0}])

      assert Task.await(waiter, 1_000) == {:error, {:canceled, unquote(reason)}}
      assert Task.await(reader, 1_000) == [{:canceled, unquote(reason)}]

      assert_receive {:event_stream_result, ^subscription,
                      {:error, {:canceled, unquote(reason)}}},
                     1_000

      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1_000
      assert_receive {:DOWN, ^stream_monitor, :process, ^stream, :normal}, 1_000
    end
  end

  test "the facade injects cooperative abort without changing canonical cancellation" do
    signal = AbortSignal.new()
    stream = start_stream(abort_signal: signal)
    worker = waiting_process()
    monitor = Process.monitor(worker)
    :ok = EventStream.attach_task(stream, worker)
    {:ok, subscription} = AiStream.subscribe_result(stream)
    refute AbortSignal.aborted?(signal)

    assert :ok = EventStream.cancel(stream, :user_requested)

    assert_receive {:event_stream_result, ^subscription, {:error, {:canceled, :user_requested}}},
                   1_000

    assert AbortSignal.aborted?(signal)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :shutdown}, 1_000
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

  defp await_consumers(stream) do
    await(fn ->
      state = :sys.get_state(stream)
      :queue.len(state.take_waiters) == 1 and :queue.len(state.result_waiters) == 2
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
