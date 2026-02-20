defmodule LemonCore.ClockTest do
  use ExUnit.Case

  alias LemonCore.Clock

  describe "now_ms/0" do
    test "returns current time in milliseconds" do
      before = System.system_time(:millisecond)
      result = Clock.now_ms()
      after_time = System.system_time(:millisecond)

      assert is_integer(result)
      assert result >= before
      assert result <= after_time
    end
  end

  describe "now_sec/0" do
    test "returns current time in seconds" do
      before = System.system_time(:second)
      result = Clock.now_sec()
      after_time = System.system_time(:second)

      assert is_integer(result)
      assert result >= before
      assert result <= after_time
    end
  end

  describe "now_utc/0" do
    test "returns current UTC datetime" do
      before = DateTime.utc_now()
      result = Clock.now_utc()
      after_time = DateTime.utc_now()

      assert %DateTime{} = result
      assert result.time_zone == "Etc/UTC"
      assert DateTime.compare(result, before) in [:gt, :eq]
      assert DateTime.compare(result, after_time) in [:lt, :eq]
    end
  end

  describe "from_ms/1" do
    test "converts milliseconds to DateTime" do
      ms = 1_700_000_000_000
      result = Clock.from_ms(ms)

      assert %DateTime{} = result
      assert result.time_zone == "Etc/UTC"
      assert DateTime.to_unix(result, :millisecond) == ms
    end

    test "converts zero milliseconds to epoch" do
      result = Clock.from_ms(0)

      assert %DateTime{} = result
      assert result.year == 1970
      assert result.month == 1
      assert result.day == 1
    end
  end

  describe "to_ms/1" do
    test "converts DateTime to milliseconds" do
      datetime = DateTime.from_unix!(1_700_000_000, :second)
      result = Clock.to_ms(datetime)

      assert is_integer(result)
      assert result == 1_700_000_000_000
    end

    test "converts UTC now to milliseconds" do
      datetime = DateTime.utc_now()
      result = Clock.to_ms(datetime)

      assert is_integer(result)
      assert result > 1_700_000_000_000
    end
  end

  describe "expired?/2" do
    test "returns true when timestamp has expired" do
      old_timestamp = Clock.now_ms() - 10_000
      ttl = 5_000

      assert Clock.expired?(old_timestamp, ttl) == true
    end

    test "returns false when timestamp has not expired" do
      recent_timestamp = Clock.now_ms() - 1_000
      ttl = 5_000

      assert Clock.expired?(recent_timestamp, ttl) == false
    end

    test "returns false at exact TTL boundary" do
      now = Clock.now_ms()
      ttl = 5_000

      assert Clock.expired?(now - ttl, ttl) == false
    end
  end

  describe "elapsed_ms/1" do
    test "returns elapsed time since timestamp" do
      past = Clock.now_ms() - 5_000
      elapsed = Clock.elapsed_ms(past)

      assert is_integer(elapsed)
      assert elapsed >= 5_000
      assert elapsed < 6_000
    end

    test "returns negative for future timestamps" do
      future = Clock.now_ms() + 5_000
      elapsed = Clock.elapsed_ms(future)

      assert is_integer(elapsed)
      assert elapsed < 0
    end
  end

  describe "round-trip conversion" do
    test "from_ms and to_ms are inverse operations" do
      original_ms = 1_700_000_000_123
      datetime = Clock.from_ms(original_ms)
      converted_ms = Clock.to_ms(datetime)

      assert converted_ms == original_ms
    end

    test "now_ms and from_ms are consistent" do
      ms = Clock.now_ms()
      datetime = Clock.from_ms(ms)
      converted_ms = Clock.to_ms(datetime)

      assert converted_ms == ms
    end
  end
end
