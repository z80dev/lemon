defmodule LemonCore.BusTest do
  use ExUnit.Case, async: true

  alias LemonCore.{Bus, Event}

  describe "subscribe/1 and broadcast/2" do
    test "subscriber receives broadcasted events" do
      topic = "test:#{System.unique_integer()}"
      Bus.subscribe(topic)

      event = Event.new(:test_event, %{data: "hello"})
      Bus.broadcast(topic, event)

      assert_receive %Event{type: :test_event, payload: %{data: "hello"}}
    end

    test "multiple subscribers receive the same event" do
      topic = "test:#{System.unique_integer()}"

      # Subscribe from current process
      Bus.subscribe(topic)

      # Spawn another subscriber
      parent = self()
      spawn(fn ->
        Bus.subscribe(topic)
        send(parent, :subscribed)
        receive do
          event -> send(parent, {:child_received, event})
        end
      end)

      assert_receive :subscribed

      event = Event.new(:multi_test, %{value: 42})
      Bus.broadcast(topic, event)

      # Current process receives
      assert_receive %Event{type: :multi_test}
      # Child process receives
      assert_receive {:child_received, %Event{type: :multi_test}}
    end

    test "unsubscribed process does not receive events" do
      topic = "test:#{System.unique_integer()}"
      Bus.subscribe(topic)
      Bus.unsubscribe(topic)

      Bus.broadcast(topic, Event.new(:should_not_receive, %{}))

      refute_receive %Event{type: :should_not_receive}, 100
    end
  end

  describe "broadcast_from/2" do
    test "sender does not receive their own broadcast" do
      topic = "test:#{System.unique_integer()}"
      Bus.subscribe(topic)

      Bus.broadcast_from(topic, Event.new(:from_self, %{}))

      refute_receive %Event{type: :from_self}, 100
    end
  end

  describe "topic helpers" do
    test "run_topic/1 builds correct topic" do
      assert Bus.run_topic("abc-123") == "run:abc-123"
    end

    test "session_topic/1 builds correct topic" do
      assert Bus.session_topic("agent:main:abc") == "session:agent:main:abc"
    end
  end
end
