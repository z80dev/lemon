defmodule LemonAutomation.CronScheduleTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.CronSchedule

  describe "normalize/1" do
    test "keeps 5-field cron expressions unchanged" do
      assert CronSchedule.normalize("0 9 * * 1-5") == {:ok, "0 9 * * 1-5"}
    end

    test "normalizes interval shorthands" do
      assert CronSchedule.normalize("every 30m") == {:ok, "*/30 * * * *"}
      assert CronSchedule.normalize("15 minutes") == {:ok, "*/15 * * * *"}
      assert CronSchedule.normalize("every 2h") == {:ok, "0 */2 * * *"}
      assert CronSchedule.normalize("hourly") == {:ok, "0 * * * *"}
      assert CronSchedule.normalize("60 minutes") == {:ok, "0 * * * *"}
      assert CronSchedule.normalize("every 24h") == {:ok, "0 0 * * *"}
    end

    test "rejects interval shorthands that do not map cleanly to cron steps" do
      assert CronSchedule.normalize("every 45m") ==
               {:error, "Minute interval must evenly divide 60"}

      assert CronSchedule.normalize("every 7h") ==
               {:error, "Hour interval must evenly divide 24"}
    end

    test "normalizes daily and weekday time shorthands" do
      assert CronSchedule.normalize("daily at 9am") == {:ok, "0 9 * * *"}
      assert CronSchedule.normalize("every day at 17:45") == {:ok, "45 17 * * *"}
      assert CronSchedule.normalize("weekdays at 09:30") == {:ok, "30 9 * * 1-5"}
    end

    test "normalizes weekly day-name shorthands" do
      assert CronSchedule.normalize("weekly monday at 8am") == {:ok, "0 8 * * 1"}
      assert CronSchedule.normalize("every friday at 18:15") == {:ok, "15 18 * * 5"}
      assert CronSchedule.normalize("sundays at 10pm") == {:ok, "0 22 * * 0"}
    end

    test "returns unknown schedule text for normal validation errors" do
      assert CronSchedule.normalize("daily after lunch") == {:ok, "daily after lunch"}
    end
  end

  describe "parse/1" do
    test "parses simple wildcard expression" do
      assert {:ok, parsed} = CronSchedule.parse("* * * * *")
      assert parsed.minute == Enum.to_list(0..59)
      assert parsed.hour == Enum.to_list(0..23)
      assert parsed.day == Enum.to_list(1..31)
      assert parsed.month == Enum.to_list(1..12)
      assert parsed.weekday == Enum.to_list(0..6)
    end

    test "parses specific values" do
      assert {:ok, parsed} = CronSchedule.parse("30 9 15 6 1")
      assert parsed.minute == [30]
      assert parsed.hour == [9]
      assert parsed.day == [15]
      assert parsed.month == [6]
      assert parsed.weekday == [1]
    end

    test "parses step values" do
      assert {:ok, parsed} = CronSchedule.parse("*/15 */6 * * *")
      assert parsed.minute == [0, 15, 30, 45]
      assert parsed.hour == [0, 6, 12, 18]
    end

    test "parses range values" do
      assert {:ok, parsed} = CronSchedule.parse("0-30 9-17 * * *")
      assert parsed.minute == Enum.to_list(0..30)
      assert parsed.hour == Enum.to_list(9..17)
    end

    test "parses list values" do
      assert {:ok, parsed} = CronSchedule.parse("0,15,30,45 9,12,18 * * *")
      assert parsed.minute == [0, 15, 30, 45]
      assert parsed.hour == [9, 12, 18]
    end

    test "parses mixed list and range" do
      assert {:ok, parsed} = CronSchedule.parse("0,30 9-12,18 * * *")
      assert parsed.minute == [0, 30]
      assert parsed.hour == [9, 10, 11, 12, 18]
    end

    test "normalizes weekday 7 to 0 (Sunday)" do
      assert {:ok, parsed} = CronSchedule.parse("* * * * 7")
      assert parsed.weekday == [0]
    end

    test "handles both 0 and 7 for Sunday" do
      assert {:ok, parsed} = CronSchedule.parse("* * * * 0,7")
      assert parsed.weekday == [0]
    end

    test "returns error for invalid field count" do
      assert {:error, msg} = CronSchedule.parse("* * *")
      assert msg =~ "Expected 5 fields"
    end

    test "parses normalized schedule shorthands" do
      assert {:ok, parsed} = CronSchedule.parse("daily at 9am")
      assert parsed.minute == [0]
      assert parsed.hour == [9]

      assert {:ok, parsed} = CronSchedule.parse("weekdays at 09:30")
      assert parsed.minute == [30]
      assert parsed.hour == [9]
      assert parsed.weekday == [1, 2, 3, 4, 5]
    end

    test "returns error for invalid value" do
      assert {:error, msg} = CronSchedule.parse("60 * * * *")
      assert msg =~ "out of range"
    end

    test "returns error for invalid step" do
      assert {:error, msg} = CronSchedule.parse("*/0 * * * *")
      assert msg =~ "Invalid step"
    end

    test "returns error for invalid range" do
      assert {:error, msg} = CronSchedule.parse("30-10 * * * *")
      assert msg =~ "Invalid range"
    end
  end

  describe "valid?/1" do
    test "returns true for valid expressions" do
      assert CronSchedule.valid?("* * * * *")
      assert CronSchedule.valid?("0 9 * * *")
      assert CronSchedule.valid?("*/15 * * * 1-5")
    end

    test "returns false for invalid expressions" do
      refute CronSchedule.valid?("invalid")
      refute CronSchedule.valid?("60 * * * *")
      refute CronSchedule.valid?("* * * *")
    end
  end

  describe "next_run_ms/2" do
    test "returns milliseconds timestamp" do
      result = CronSchedule.next_run_ms("* * * * *", "UTC")
      assert is_integer(result)
      assert result > System.system_time(:millisecond)
    end

    test "returns nil for invalid expression" do
      assert CronSchedule.next_run_ms("invalid", "UTC") == nil
    end
  end

  describe "next_run_datetime/2" do
    test "returns DateTime for valid expression" do
      result = CronSchedule.next_run_datetime("* * * * *", "UTC")
      assert %DateTime{} = result
      assert DateTime.compare(result, DateTime.utc_now()) == :gt
    end

    test "respects minute field" do
      # Run at minute 0 of any hour
      result = CronSchedule.next_run_datetime("0 * * * *", "UTC")
      assert result.minute == 0
    end

    test "respects hour field" do
      # Run at 9:00 any day
      result = CronSchedule.next_run_datetime("0 9 * * *", "UTC")
      assert result.minute == 0
      assert result.hour == 9
    end

    test "returns nil for invalid expression" do
      assert CronSchedule.next_run_datetime("invalid", "UTC") == nil
    end
  end

  describe "next_runs/3" do
    test "returns multiple future times" do
      results = CronSchedule.next_runs("* * * * *", "UTC", count: 5)
      assert length(results) == 5

      # Each time should be after the previous
      results
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] ->
        assert DateTime.compare(b, a) == :gt
      end)
    end

    test "respects count option" do
      results = CronSchedule.next_runs("* * * * *", "UTC", count: 10)
      assert length(results) == 10
    end

    test "returns empty list for invalid expression" do
      assert CronSchedule.next_runs("invalid", "UTC") == []
    end
  end

  describe "matches?/2" do
    test "returns true when datetime matches expression" do
      # Create a datetime at exactly 9:00
      dt = %DateTime{
        year: 2024,
        month: 6,
        day: 15,
        hour: 9,
        minute: 0,
        second: 0,
        microsecond: {0, 0},
        time_zone: "Etc/UTC",
        zone_abbr: "UTC",
        utc_offset: 0,
        std_offset: 0
      }

      assert CronSchedule.matches?("0 9 * * *", dt)
      assert CronSchedule.matches?("* * * * *", dt)
      assert CronSchedule.matches?("0 * * * *", dt)
    end

    test "returns false when datetime does not match" do
      dt = %DateTime{
        year: 2024,
        month: 6,
        day: 15,
        hour: 10,
        minute: 30,
        second: 0,
        microsecond: {0, 0},
        time_zone: "Etc/UTC",
        zone_abbr: "UTC",
        utc_offset: 0,
        std_offset: 0
      }

      refute CronSchedule.matches?("0 9 * * *", dt)
      refute CronSchedule.matches?("0 * * * *", dt)
    end

    test "returns false for invalid expression" do
      refute CronSchedule.matches?("invalid", DateTime.utc_now())
    end
  end

  describe "common cron patterns" do
    test "every minute" do
      assert {:ok, _} = CronSchedule.parse("* * * * *")
    end

    test "every hour at minute 0" do
      assert {:ok, parsed} = CronSchedule.parse("0 * * * *")
      assert parsed.minute == [0]
    end

    test "daily at 9 AM" do
      assert {:ok, parsed} = CronSchedule.parse("0 9 * * *")
      assert parsed.minute == [0]
      assert parsed.hour == [9]
    end

    test "weekdays at 9 AM" do
      assert {:ok, parsed} = CronSchedule.parse("0 9 * * 1-5")
      assert parsed.weekday == [1, 2, 3, 4, 5]
    end

    test "every 15 minutes" do
      assert {:ok, parsed} = CronSchedule.parse("*/15 * * * *")
      assert parsed.minute == [0, 15, 30, 45]
    end

    test "twice daily at 9 AM and 6 PM" do
      assert {:ok, parsed} = CronSchedule.parse("0 9,18 * * *")
      assert parsed.hour == [9, 18]
    end

    test "first of month at midnight" do
      assert {:ok, parsed} = CronSchedule.parse("0 0 1 * *")
      assert parsed.day == [1]
    end

    test "monday at 8:30 AM" do
      assert {:ok, parsed} = CronSchedule.parse("30 8 * * 1")
      assert parsed.minute == [30]
      assert parsed.hour == [8]
      assert parsed.weekday == [1]
    end
  end
end
