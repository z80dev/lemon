defmodule LemonCore.ClockTest do
  @moduledoc """
  Tests for the Clock module.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Clock

  doctest LemonCore.Clock

  describe "now_ms/0" do
    test "returns current time in milliseconds" do
      before = System.system_time(:millisecond)
      now = Clock.now_ms()
      after_time = System.system_time(:millisecond)

      assert is_integer(now)
      assert now >= before
      assert now <= after_time
    end
  end

  describe "now_sec/0" do
    test "returns current time in seconds" do
      before = System.system_time(:second)
      now = Clock.now_sec()
      after_time = System.system_time(:second)

      assert is_integer(now)
      assert now >= before
      assert now <= after_time
    end
  end

  describe "now_utc/0" do
    test "returns current UTC datetime" do
      before = DateTime.utc_now()
      now = Clock.now_utc()
      after_time = DateTime.utc_now()

      assert %DateTime{} = now
      assert now.time_zone == "Etc/UTC"
      assert DateTime.compare(now, before) in [:gt, :eq]
      assert DateTime.compare(now, after_time) in [:lt, :eq]
    end
  end

  describe "from_ms/1" do
    test "converts milliseconds to DateTime" do
      ms = 1_600_000_000_000
      datetime = Clock.from_ms(ms)

      assert %DateTime{} = datetime
      assert DateTime.to_unix(datetime, :millisecond) == ms
    end

    test "handles zero" do
      datetime = Clock.from_ms(0)

      assert %DateTime{} = datetime
      assert datetime.year == 1970
    end
  end

  describe "to_ms/1" do
    test "converts known timestamp deterministically" do
      datetime = DateTime.from_unix!(1_700_000_000, :second)
      ms = Clock.to_ms(datetime)

      assert is_integer(ms)
      assert ms == 1_700_000_000_000
    end

    test "converts DateTime to milliseconds" do
      datetime = DateTime.utc_now()
      ms = Clock.to_ms(datetime)

      assert is_integer(ms)
      assert ms > 0
    end

    test "round-trips correctly with from_ms" do
      original_ms = 1_600_000_000_000
      datetime = Clock.from_ms(original_ms)
      converted_ms = Clock.to_ms(datetime)

      assert converted_ms == original_ms
    end
  end

  describe "expired?/2" do
    test "returns true when timestamp is expired" do
      old_timestamp = Clock.now_ms() - 10_000
      ttl = 5_000

      assert Clock.expired?(old_timestamp, ttl) == true
    end

    test "returns false when timestamp is not expired" do
      recent_timestamp = Clock.now_ms() - 1_000
      ttl = 5_000

      assert Clock.expired?(recent_timestamp, ttl) == false
    end

    test "returns false at exact boundary" do
      now = Clock.now_ms()
      ttl = 5_000

      assert Clock.expired?(now - ttl, ttl) == false
    end

    test "returns true just past boundary" do
      now = Clock.now_ms()
      ttl = 5_000

      assert Clock.expired?(now - ttl - 1, ttl) == true
    end
  end

  describe "elapsed_ms/1" do
    test "returns elapsed time since timestamp" do
      past = Clock.now_ms() - 1_000
      elapsed = Clock.elapsed_ms(past)

      assert is_integer(elapsed)
      assert elapsed >= 1_000
      assert elapsed < 2_000
    end

    test "returns 0 for current timestamp" do
      now = Clock.now_ms()
      elapsed = Clock.elapsed_ms(now)

      assert elapsed >= 0
      assert elapsed < 100
    end

    test "returns negative for future timestamps" do
      future = Clock.now_ms() + 5_000
      elapsed = Clock.elapsed_ms(future)

      assert is_integer(elapsed)
      assert elapsed < 0
    end
  end
end
