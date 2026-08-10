defmodule LemonCore.BusRegistryFallbackTest do
  @moduledoc """
  Exercises the pubsub-free path of `LemonCore.Bus`.

  `phoenix_pubsub` is present in the umbrella, so the fallback is forced with
  `config :lemon_core, :bus_backend, :registry` rather than by removing the
  dependency. That mutates app env, hence `async: false`.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{Bus, Event}

  setup do
    original = Application.get_env(:lemon_core, :bus_backend)
    start_supervised!({Registry, keys: :duplicate, name: LemonCore.Bus.Registry})
    Application.put_env(:lemon_core, :bus_backend, :registry)

    on_exit(fn ->
      if original do
        Application.put_env(:lemon_core, :bus_backend, original)
      else
        Application.delete_env(:lemon_core, :bus_backend)
      end
    end)

    :ok
  end

  test "the backend switch is observable" do
    refute Bus.pubsub?()

    assert {Registry, keys: :duplicate, name: LemonCore.Bus.Registry} =
             Bus.child_spec_for_backend()
  end

  test "subscribers receive broadcasts" do
    topic = "fallback:#{System.unique_integer([:positive])}"
    assert Bus.subscribe(topic) == :ok

    Bus.broadcast(topic, Event.new(:hello, %{n: 1}))

    assert_receive %Event{type: :hello, payload: %{n: 1}}
  end

  test "unsubscribe clears repeated subscriptions" do
    topic = "fallback:#{System.unique_integer([:positive])}"
    assert Bus.subscribe(topic) == :ok
    assert Bus.subscribe(topic) == :ok

    Bus.unsubscribe(topic)
    Bus.broadcast(topic, Event.new(:gone, %{}))

    refute_receive %Event{type: :gone}, 50
  end

  test "only subscribers of the topic receive the event" do
    mine = "fallback:#{System.unique_integer([:positive])}"
    other = "fallback:#{System.unique_integer([:positive])}"
    Bus.subscribe(mine)

    Bus.broadcast(other, Event.new(:elsewhere, %{}))

    refute_receive %Event{type: :elsewhere}, 50
  end

  test "multiple subscribers all receive the event" do
    topic = "fallback:#{System.unique_integer([:positive])}"
    parent = self()

    spawn(fn ->
      Bus.subscribe(topic)
      send(parent, :ready)

      receive do
        event -> send(parent, {:child_received, event})
      end
    end)

    assert_receive :ready
    Bus.subscribe(topic)

    Bus.broadcast(topic, Event.new(:fanout, %{}))

    assert_receive %Event{type: :fanout}
    assert_receive {:child_received, %Event{type: :fanout}}
  end

  test "unsubscribe stops delivery" do
    topic = "fallback:#{System.unique_integer([:positive])}"
    Bus.subscribe(topic)
    assert Bus.unsubscribe(topic) == :ok

    Bus.broadcast(topic, Event.new(:silent, %{}))

    refute_receive %Event{type: :silent}, 50
  end

  test "broadcast_from/2 excludes the sender" do
    topic = "fallback:#{System.unique_integer([:positive])}"
    parent = self()

    spawn(fn ->
      Bus.subscribe(topic)
      send(parent, :ready)

      receive do
        event -> send(parent, {:child_received, event})
      end
    end)

    assert_receive :ready
    Bus.subscribe(topic)

    Bus.broadcast_from(topic, Event.new(:not_mine, %{}))

    assert_receive {:child_received, %Event{type: :not_mine}}
    refute_receive %Event{type: :not_mine}, 50
  end

  describe "running?/0" do
    test "reports the Registry backend as running" do
      assert Bus.running?(),
             "the Registry backend is started, so publishers gating on running?/0 must publish"
    end

    test "follows the active backend's process, not LemonCore.PubSub" do
      # The regression this guards: four publishers gated on
      # `Process.whereis(LemonCore.PubSub)`, so under this backend they broadcast nothing and
      # said nothing about it. Checkpoints, goal events, kanban events and coalesced output
      # were all silently dropped in any deployment using the fallback.
      assert is_pid(Process.whereis(LemonCore.Bus.Registry))
      assert Bus.running?()

      # Forcing the other backend makes running?/0 report on that backend's process instead,
      # which is what "follows the active backend" has to mean.
      Application.put_env(:lemon_core, :bus_backend, :pubsub)
      assert Bus.running?() == is_pid(Process.whereis(LemonCore.PubSub))
      Application.put_env(:lemon_core, :bus_backend, :registry)
    end
  end

  describe "typed events under the Registry backend" do
    test "a struct payload survives the fallback intact" do
      topic = "fallback:#{System.unique_integer([:positive])}"
      Bus.subscribe(topic)

      payload =
        LemonCore.Events.RoutingFeedback.new(%{
          fingerprint_key: "fp_registry_fallback",
          outcome: :success,
          duration_ms: 12
        })

      assert Bus.broadcast_event(topic, :routing_feedback, payload) == :ok

      assert_receive %Event{type: :routing_feedback, payload: ^payload}
    end

    test "broadcast_event/4 still rejects a mismatched payload" do
      assert_raise ArgumentError, fn ->
        Bus.broadcast_event("fallback:mismatch", :routing_feedback, %{not: :a_struct})
      end
    end
  end
end
