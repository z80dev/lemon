defmodule LemonAgent.EventStreamTest do
  use ExUnit.Case, async: false

  alias LemonAgent.{AbortSignal, EventStream}

  test "cancel aborts the supplied signal before shutting down the task" do
    signal = AbortSignal.new()
    stream = start_stream(abort_signal: signal)
    parent = self()

    worker =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(parent, {:ready, self()})

        receive do
          {:EXIT, ^stream, :shutdown} -> send(parent, {:shutdown, AbortSignal.aborted?(signal)})
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:ready, ^worker}, 1_000
    assert :ok = EventStream.attach_task(stream, worker)
    refute AbortSignal.aborted?(signal)
    assert :ok = EventStream.cancel(stream, :user_requested)
    assert_receive {:shutdown, true}, 1_000
  end

  test "without an abort signal cancellation does not run a caller's on_cancel callback" do
    signal = AbortSignal.new()
    stream = start_stream(event_format: :agent, on_cancel: fn -> AbortSignal.abort(signal) end)
    assert :ok = EventStream.cancel(stream)
    assert [{:canceled, :canceled}] = Enum.to_list(EventStream.events(stream))
    refute AbortSignal.aborted?(signal)
  end

  test "agent completion survives late cancellation and yields agent_end messages" do
    {:ok, stream} = EventStream.start_link(event_format: :provider)
    messages = [%{role: :assistant, content: "answer"}]

    assert :ok = EventStream.complete(stream, messages)
    assert :ok = EventStream.cancel(stream, :too_late)
    assert {:ok, ^messages} = EventStream.result(stream, 1_000)
    assert [{:agent_end, ^messages}] = Enum.to_list(EventStream.events(stream))
  end

  test "agent error survives late cancellation with its reason and partial state" do
    partial = %{messages: [%{role: :assistant, content: "partial answer"}]}

    for {failure, state} <- [{:tool_failed, partial}, {"agent failure", nil}] do
      stream = start_stream(event_format: :provider)

      assert :ok =
               if(state,
                 do: EventStream.error(stream, failure, state),
                 else: EventStream.error(stream, failure)
               )

      assert :ok = EventStream.cancel(stream, :too_late)
      assert {:error, ^failure, ^state} = EventStream.result(stream, 1_000)
      assert [{:error, ^failure, ^state}] = Enum.to_list(EventStream.events(stream))
    end
  end

  test "attached task failure uses the agent error event and result" do
    stream = start_stream(event_format: :provider)
    worker = spawn(fn -> receive do: (:crash -> exit(:bad_tool)) end)
    on_exit(fn -> Process.exit(worker, :kill) end)
    assert :ok = EventStream.attach_task(stream, worker)
    # Ensure the monitor is installed before the equivalent of a tool crash.
    assert EventStream.stats(stream).queue_size == 0
    send(worker, :crash)
    assert {:error, {:task_crashed, :bad_tool}, nil} = EventStream.result(stream, 1_000)
    assert [{:error, {:task_crashed, :bad_tool}, nil}] = Enum.to_list(EventStream.events(stream))
  end

  test "the configured task shutdown grace is used before forcing shutdown" do
    put_grace(250)
    stream = start_stream(task_shutdown_grace_ms: 1)
    assert :sys.get_state(stream).task_shutdown_grace_ms == 250
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        send(parent, {:ready, self()})

        receive do
          {:EXIT, ^stream, :shutdown} -> send(parent, {:shutdown, self()})
        end

        receive do: (:never -> :ok)
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:ready, ^worker}, 1_000
    assert :ok = EventStream.attach_task(stream, worker)
    started = System.monotonic_time(:millisecond)
    assert :ok = EventStream.cancel(stream)
    assert_receive {:shutdown, ^worker}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert System.monotonic_time(:millisecond) - started >= 250
  end

  test "missing or invalid task shutdown grace falls back to 100 ms" do
    put_grace(:unset)

    for configured <- [:unset, :invalid, 0, -1] do
      if configured != :unset,
        do: Application.put_env(:lemon_agent, :event_stream_cancel_grace_ms, configured)

      stream = start_stream(task_shutdown_grace_ms: 321)
      assert :sys.get_state(stream).task_shutdown_grace_ms == 100
    end
  end

  defp start_stream(opts) do
    {:ok, stream} = EventStream.start(opts)
    stream
  end

  defp put_grace(value) do
    app = :lemon_agent
    key = :event_stream_cancel_grace_ms
    previous = Application.fetch_env(app, key)

    on_exit(fn ->
      case previous do
        {:ok, previous} -> Application.put_env(app, key, previous)
        :error -> Application.delete_env(app, key)
      end
    end)

    if value == :unset,
      do: Application.delete_env(app, key),
      else: Application.put_env(app, key, value)
  end
end
