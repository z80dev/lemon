defmodule LemonCore.EventTest do
  use ExUnit.Case, async: true

  alias LemonCore.Event

  describe "new/2" do
    test "creates event with type and payload" do
      event = Event.new(:test_event, %{data: "hello"})

      assert event.type == :test_event
      assert event.payload == %{data: "hello"}
      assert event.meta == nil
      assert is_integer(event.ts_ms)
      assert event.ts_ms > 0
    end
  end

  describe "new/3" do
    test "creates event with meta" do
      meta = %{run_id: "abc", session_key: "xyz"}
      event = Event.new(:delta, %{text: "hi"}, meta)

      assert event.type == :delta
      assert event.payload == %{text: "hi"}
      assert event.meta == meta
    end
  end

  describe "new_with_ts/4" do
    test "creates event with specific timestamp" do
      ts = 1234567890
      event = Event.new_with_ts(:historic, ts, %{old: true})

      assert event.ts_ms == ts
      assert event.type == :historic
    end
  end

  describe "now_ms/0" do
    test "returns current time in milliseconds" do
      before = System.system_time(:millisecond)
      result = Event.now_ms()
      after_time = System.system_time(:millisecond)

      assert result >= before
      assert result <= after_time
    end
  end
end
