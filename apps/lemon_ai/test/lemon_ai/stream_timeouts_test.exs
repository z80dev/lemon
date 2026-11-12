defmodule LemonAi.StreamTimeoutsTest do
  use ExUnit.Case, async: true

  alias LemonAi.{CallDispatcher, EventStream}
  alias LemonAi.Providers.StreamingHelper
  alias LemonAi.Types.{AssistantMessage, Context, Model, StreamOptions}

  for mode <- [:direct, :dispatched] do
    @mode mode
    @idle_reason if(mode == :direct,
                   do: :stream_idle_timeout,
                   else: :dispatcher_stream_idle_timeout
                 )
    @hard_reason if(mode == :direct, do: :timeout, else: :dispatcher_stream_timeout)

    test "#{mode}: every event keeps a slow provider alive beyond the inactivity window" do
      {stream, provider} = start_provider(@mode, stream_idle_timeout: 200, stream_timeout: 2_000)
      message = %AssistantMessage{stop_reason: :stop}
      started = System.monotonic_time(:millisecond)

      for kind <- [:start, :thinking_delta, :text_delta, :tool_call_delta, :text_end, :heartbeat] do
        # Short windows reproduce a generation lasting longer than the old
        # absolute-limit equivalent without a multi-minute test.
        receive do
        after
          60 -> :ok
        end

        send(provider, {:emit, {kind, 0, "delta", message}, self()})
        assert_receive {:emitted, ^provider, :ok}, 1_000
      end

      assert System.monotonic_time(:millisecond) - started > 200
      send(provider, {:complete, message})
      assert EventStream.result(stream, 1_000) == {:ok, message}
      assert Enum.count(EventStream.events(stream)) == 7
    end

    test "#{mode}: silence cancels the provider with a distinct idle reason" do
      {stream, provider} = start_provider(@mode, stream_idle_timeout: 80, stream_timeout: 2_000)
      ref = Process.monitor(provider)
      assert EventStream.result(stream, 1_000) == {:error, {:canceled, @idle_reason}}
      assert_receive {:DOWN, ^ref, :process, ^provider, :shutdown}, 1_000
    end

    test "#{mode}: activity never extends the hard ceiling" do
      {stream, provider} = start_provider(@mode, stream_idle_timeout: 200, stream_timeout: 300)
      ref = Process.monitor(provider)

      for _ <- 1..4 do
        receive do
        after
          50 -> :ok
        end

        send(provider, {:emit, {:thinking_delta, 0, "thinking", %AssistantMessage{}}, self()})
        assert_receive {:emitted, ^provider, :ok}, 1_000
      end

      assert EventStream.result(stream, 1_000) == {:error, {:canceled, @hard_reason}}
      assert_receive {:DOWN, ^ref, :process, ^provider, :shutdown}, 1_000
    end
  end

  test "a queued stale idle timer cannot cancel an active or completed stream" do
    {:ok, stream} = EventStream.start_link(timeout: :infinity, idle_timeout: 1_000)
    old_ref = :sys.get_state(stream).idle_timeout_ref
    assert :ok = EventStream.push(stream, {:heartbeat, 1})
    current_ref = :sys.get_state(stream).idle_timeout_ref
    refute current_ref == old_ref
    send(stream, {:timeout, old_ref, :stream_idle_timeout})
    assert :ok = EventStream.push(stream, {:heartbeat, 2})
    current_ref = :sys.get_state(stream).idle_timeout_ref

    message = %AssistantMessage{stop_reason: :stop}
    EventStream.complete(stream, message)
    send(stream, {:timeout, current_ref, :stream_idle_timeout})
    assert EventStream.result(stream) == {:ok, message}
  end

  defp start_provider(mode, overrides) do
    owner = self()
    opts = struct(StreamOptions, overrides)

    model = %Model{
      id: "slow",
      name: "Slow",
      api: :test,
      provider: "timeout-#{inspect(make_ref())}"
    }

    callback = fn ->
      StreamingHelper.start_streaming(model, %Context{}, opts, fn stream, _, _, _ ->
        send(owner, {:provider, self()})
        produce(stream)
      end)
    end

    {:ok, stream} =
      case mode do
        :direct -> callback.()
        :dispatched -> CallDispatcher.dispatch(model.provider, callback, overrides)
      end

    assert_receive {:provider, provider}, 1_000
    {stream, provider}
  end

  defp produce(stream) do
    receive do
      {:emit, event, caller} ->
        send(caller, {:emitted, self(), EventStream.push(stream, event)})
        produce(stream)

      {:complete, message} ->
        EventStream.complete(stream, message)
    end
  end
end
