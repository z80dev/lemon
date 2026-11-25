defmodule LemonAutomation.ChatCommands.ReminderParserTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.ChatCommands.ReminderParser, as: Parser

  # Sunday 2026-09-27 10:15:30 server-local time.
  @now ~N[2026-09-27 10:15:30]

  defp parse(text, now \\ @now), do: Parser.parse(text, now: now)

  defp assert_parsed(text, schedule, once, what) do
    assert {:ok, %{schedule: ^schedule, once: ^once, text: ^what} = parsed} = parse(text)
    parsed
  end

  describe "acceptance examples" do
    test "9am stand-up rolls to tomorrow because 9am already passed today" do
      parsed = assert_parsed("9am stand-up", "0 9 28 9 *", true, "stand-up")
      assert parsed.description == "once at Mon 2026-09-28 09:00"
    end

    test "in 20m check oven rounds the target up to the next whole minute" do
      # 10:15:30 + 20m = 10:35:30 -> 10:36
      parsed = assert_parsed("in 20m check oven", "36 10 27 9 *", true, "check oven")
      assert parsed.description == "once at Sun 2026-09-27 10:36"
    end

    test "every weekday 8:30 daily brief keeps 'daily brief' as the text" do
      parsed =
        assert_parsed("every weekday 8:30 daily brief", "30 8 * * 1-5", false, "daily brief")

      assert parsed.description == "every weekday at 08:30"
    end
  end

  describe "relative one-shot" do
    test "accepts unit spellings and compound durations" do
      assert_parsed("in 20 min x", "36 10 27 9 *", true, "x")
      assert_parsed("in 20 minutes x", "36 10 27 9 *", true, "x")
      assert_parsed("in 2h x", "16 12 27 9 *", true, "x")
      assert_parsed("in 2 hours x", "16 12 27 9 *", true, "x")
      assert_parsed("in 1h30m x", "46 11 27 9 *", true, "x")
      assert_parsed("in 3d x", "16 10 30 9 *", true, "x")
      assert_parsed("in 3 days x", "16 10 30 9 *", true, "x")
    end

    test "an exact minute is not rounded up" do
      assert {:ok, %{schedule: "35 10 27 9 *"}} = parse("in 20m x", ~N[2026-09-27 10:15:00])
    end

    test "crosses month boundaries" do
      assert {:ok, %{schedule: "5 0 1 10 *"}} = parse("in 10m x", ~N[2026-09-30 23:55:00])
    end

    test "is case-insensitive and preserves the text's case" do
      assert_parsed("IN 20M Check Oven", "36 10 27 9 *", true, "Check Oven")
    end

    test "rejects zero, unknown units, and delays a pinned date cannot express" do
      assert {:error, _} = parse("in 0m x")
      assert {:error, _} = parse("in 20 mail x")
      assert {:error, message} = parse("in 400d x")
      assert message =~ "364 days"
    end
  end

  describe "clock one-shot" do
    test "later today stays today" do
      assert_parsed("9:30pm x", "30 21 27 9 *", true, "x")
      assert_parsed("21:15 x", "15 21 27 9 *", true, "x")
      assert_parsed("noon lunch", "0 12 27 9 *", true, "lunch")
      assert_parsed("10:16 x", "16 10 27 9 *", true, "x")
    end

    test "the current or an earlier minute rolls to tomorrow" do
      assert_parsed("10:15 x", "15 10 28 9 *", true, "x")
      assert_parsed("midnight snack", "0 0 28 9 *", true, "snack")
      assert_parsed("at 9am x", "0 9 28 9 *", true, "x")
    end

    test "at allows bare hours and spaced am/pm" do
      assert_parsed("at 10 x", "0 10 28 9 *", true, "x")
      assert_parsed("at 11 pm x", "0 23 27 9 *", true, "x")
    end

    test "12am and 12pm map to midnight and noon" do
      assert_parsed("12am x", "0 0 28 9 *", true, "x")
      assert_parsed("12pm x", "0 12 27 9 *", true, "x")
    end

    test "tomorrow pins the next date" do
      assert_parsed("tomorrow 9am dentist", "0 9 28 9 *", true, "dentist")
      assert_parsed("tomorrow at 9:45 pm dentist", "45 21 28 9 *", true, "dentist")
    end

    test "a bare leading number is text, not a time" do
      assert {:error, _} = parse("5 things to buy")
      assert {:error, _} = parse("9 amazing things")
    end
  end

  describe "recurring" do
    test "daily forms" do
      for text <- ["every day 8:30 brief", "daily 8:30 brief", "daily at 8:30 brief"] do
        parsed = assert_parsed(text, "30 8 * * *", false, "brief")
        assert parsed.description == "every day at 08:30"
      end
    end

    test "weekday forms" do
      for text <- ["every weekday at 8:30 notes", "weekdays 8:30 notes"] do
        assert_parsed(text, "30 8 * * 1-5", false, "notes")
      end
    end

    test "named days and weekends" do
      parsed = assert_parsed("every monday 9am plan", "0 9 * * 1", false, "plan")
      assert parsed.description == "every Monday at 09:00"
      assert_parsed("every Fri at 5pm wrap up", "0 17 * * 5", false, "wrap up")
      assert_parsed("every sunday 10am call mom", "0 10 * * 0", false, "call mom")
      assert_parsed("every weekend 10am long run", "0 10 * * 0,6", false, "long run")
    end

    test "intervals that divide an hour or a day" do
      assert_parsed("every 30m stretch", "*/30 * * * *", false, "stretch")
      assert_parsed("every 2h water", "0 */2 * * *", false, "water")
      assert_parsed("every 60 minutes x", "0 * * * *", false, "x")
    end

    test "intervals that do not divide evenly are rejected" do
      assert {:error, message} = parse("every 7m stretch")
      assert message =~ "does not divide an hour"
      assert {:error, message} = parse("every 5h stretch")
      assert message =~ "does not divide a day"
    end
  end

  describe "invalid input" do
    test "missing text returns the usage" do
      assert {:error, message} = parse("9am")
      assert message =~ "Usage: /remind <when> <what>"
      assert {:error, _} = parse("in 20m   ")
      assert {:error, _} = parse("")
      assert {:error, _} = Parser.parse(nil)
    end

    test "invalid hours and minutes are rejected" do
      assert {:error, message} = parse("25:00 x")
      assert message =~ ~s(Invalid time "25:00")
      assert {:error, _} = parse("13pm x")
      assert {:error, _} = parse("every day 8:61 x")
      assert {:error, _} = parse("0am x")
    end
  end
end
