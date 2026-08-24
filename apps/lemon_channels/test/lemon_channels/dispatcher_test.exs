defmodule LemonChannels.DispatcherTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Dispatcher
  alias LemonCore.{DeliveryIntent, DeliveryRoute}
  alias LemonCore.Events.ChannelDelivery

  @telemetry_event [:lemon, :channels, :dispatch]

  defp intent(overrides) do
    defaults = [
      intent_id: "intent-#{System.unique_integer([:positive])}",
      run_id: "run-1",
      session_key: "agent:default:main",
      route:
        struct!(DeliveryRoute,
          channel_id: "unknown-test-channel",
          account_id: "default",
          peer_kind: :dm,
          peer_id: "123"
        ),
      kind: :final_text,
      body: %{text: "hello world"}
    ]

    struct!(DeliveryIntent, Keyword.merge(defaults, overrides))
  end

  defp attach_telemetry do
    handler_id = "dispatcher-test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @telemetry_event,
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "dispatch/1 enqueues a simple text intent" do
    assert :ok = Dispatcher.dispatch(intent([]))
  end

  test "dispatch/1 returns error when text is missing" do
    assert {:error, :missing_text} = Dispatcher.dispatch(intent(body: %{}))
  end

  describe "observability" do
    setup do
      attach_telemetry()
      :ok = LemonCore.Bus.subscribe("channels")
      on_exit(fn -> LemonCore.Bus.unsubscribe("channels") end)
      :ok
    end

    test "successful dispatch emits telemetry and a typed bus event" do
      %DeliveryIntent{intent_id: intent_id} = success = intent([])

      assert :ok = Dispatcher.dispatch(success)

      assert_receive {:telemetry, @telemetry_event, measurements, metadata}, 1_000
      assert measurements.count == 1
      assert is_integer(measurements.duration)
      assert metadata.channel_id == "unknown-test-channel"
      assert metadata.account_id == "default"
      assert metadata.kind == :final_text
      assert metadata.intent_id == intent_id
      assert metadata.run_id == "run-1"
      assert metadata.session_key == "agent:default:main"
      assert metadata.ok == true

      assert_receive %LemonCore.Event{type: :channel_delivery, payload: payload, meta: meta},
                     1_000

      assert %ChannelDelivery{
               intent_id: ^intent_id,
               run_id: "run-1",
               session_key: "agent:default:main",
               channel_id: "unknown-test-channel",
               account_id: "default",
               peer_kind: :dm,
               peer_id: "123",
               kind: :final_text,
               text_preview: "hello world",
               ok: true,
               error: nil
             } = payload

      assert is_integer(payload.duration_ms)
      assert is_integer(payload.ts_ms)
      assert meta.run_id == "run-1"
      assert meta.session_key == "agent:default:main"
    end

    test "failed dispatch emits telemetry and a bus event with ok: false" do
      %DeliveryIntent{intent_id: intent_id} = failure = intent(body: %{})

      assert {:error, :missing_text} = Dispatcher.dispatch(failure)

      assert_receive {:telemetry, @telemetry_event, _measurements, metadata}, 1_000
      assert metadata.ok == false

      assert_receive %LemonCore.Event{type: :channel_delivery, payload: payload}, 1_000

      assert %ChannelDelivery{
               intent_id: ^intent_id,
               ok: false,
               error: ":missing_text",
               text_preview: nil
             } = payload
    end

    test "text preview is truncated, never the full body" do
      long_text = String.duplicate("a", 5_000)

      assert :ok = Dispatcher.dispatch(intent(body: %{text: long_text}))

      assert_receive %LemonCore.Event{type: :channel_delivery, payload: payload}, 1_000
      assert String.length(payload.text_preview) <= 201
      assert String.starts_with?(payload.text_preview, "aaa")
      assert String.ends_with?(payload.text_preview, "…")
    end

    test "observability failure does not break the send" do
      # Force the bus broadcast to raise by making the payload construction fail:
      # a route that is not a map triggers no crash, so instead simulate a crashing
      # bus backend via a bogus configured backend.
      previous = Application.get_env(:lemon_core, :bus_backend)
      Application.put_env(:lemon_core, :bus_backend, :registry)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:lemon_core, :bus_backend)
        else
          Application.put_env(:lemon_core, :bus_backend, previous)
        end
      end)

      # Whether or not the registry backend process is running, dispatch must
      # still return the renderer's result.
      assert :ok = Dispatcher.dispatch(intent([]))
    end
  end
end
