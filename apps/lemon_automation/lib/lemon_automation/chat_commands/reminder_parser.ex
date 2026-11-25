defmodule LemonAutomation.ChatCommands.ReminderParser do
  @moduledoc """
  Deterministic parser for `/remind <when> <what>`.

  All times are server-local wall-clock times (cron timezone `"local"`).
  One-shot reminders are pinned to a concrete date (`"M H D Mo *"`, `once: true`);
  recurring reminders produce a plain five-field cron expression.

  Returns `{:ok, %{schedule: cron, once: boolean, description: text, text: what}}`
  or `{:error, message}` where `message` always ends with the usage text.
  """

  @type parsed :: %{
          schedule: String.t(),
          once: boolean(),
          description: String.t(),
          text: String.t()
        }

  # A pinned "M H D Mo *" schedule repeats yearly, so a relative delay must
  # land strictly inside the next year.
  @max_relative_minutes 364 * 24 * 60

  # Time accepted after a keyword (`at`, `tomorrow`, `daily`, `every ...`):
  # bare hours are unambiguous there.
  @loose_time ~S"(?<time>noon|midnight|\d{1,2}(?::\d{2})?(?:\s?[ap]m)?)"

  # Time accepted with no leading keyword: must carry am/pm or minutes, so
  # `/remind 5 things` is not read as 05:00.
  @strict_time ~S"(?<time>noon|midnight|\d{1,2}(?::\d{2})?\s?[ap]m|\d{1,2}:\d{2})"

  @at ~S"(?:\s+at)?\s+"
  @what ~S"\s+(?<what>\S.*)$"

  @minute_units ~S"minutes|minute|mins|min|m"
  @hour_units ~S"hours|hour|hrs|hr|h"
  @duration_unit ~S"(?:minutes|minute|mins|min|m|hours|hour|hrs|hr|h|days|day|d)(?![a-z])"

  @day_names ~S"monday|mon|tuesday|tues|tue|wednesday|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun"

  @dow %{
    "mon" => {1, "Monday"},
    "tue" => {2, "Tuesday"},
    "wed" => {3, "Wednesday"},
    "thu" => {4, "Thursday"},
    "fri" => {5, "Friday"},
    "sat" => {6, "Saturday"},
    "sun" => {0, "Sunday"}
  }

  @weekday_abbr ~w(Mon Tue Wed Thu Fri Sat Sun)

  @usage """
  Usage: /remind <when> <what>
    /remind in 20m check oven  (also in 2h, in 1h30m, in 3d)
    /remind 9am stand-up  (also 9:30pm, 21:15, at 9am, noon, midnight)
    /remind tomorrow 9am dentist
    /remind every day 8:30 daily brief  (or daily at 8:30)
    /remind every weekday 8:30 standup notes
    /remind every monday 9am plan the week
    /remind every weekend 10am long run
    /remind every 30m stretch  (minutes must divide 60, hours must divide 24)
  Times use the server's local clock. /reminders lists reminders; /unremind <id> cancels one.
  """

  @doc "Usage text listing every supported `<when>` form."
  @spec usage() :: String.t()
  def usage, do: String.trim_trailing(@usage)

  @doc """
  Parse `<when> <what>`.

  Options:
    * `:now` - `NaiveDateTime` in server local time
      (default `NaiveDateTime.from_erl!(:calendar.local_time())`)
  """
  @spec parse(String.t() | nil, keyword()) :: {:ok, parsed()} | {:error, String.t()}
  def parse(text, opts \\ [])

  def parse(text, opts) when is_binary(text) do
    now = Keyword.get_lazy(opts, :now, fn -> NaiveDateTime.from_erl!(:calendar.local_time()) end)
    text = String.trim(text)

    Enum.find_value(rules(), {:error, usage()}, fn {regex, build} ->
      case Regex.named_captures(regex, text) do
        nil -> nil
        captures -> build.(captures, now)
      end
    end)
  end

  def parse(_text, _opts), do: {:error, usage()}

  defp rules do
    [
      {~r/^in\s+(?<dur>\d+\s*#{@duration_unit}(?:\s*(?:and\s+)?\d+\s*#{@duration_unit})*)#{@what}/isu,
       &relative/2},
      {~r/^tomorrow#{@at}#{@loose_time}#{@what}/isu, &tomorrow/2},
      {~r/^(?:every\s+day|everyday|daily)#{@at}#{@loose_time}#{@what}/isu,
       &recurring(&1, &2, "*", "every day")},
      {~r/^(?:every\s+weekday|weekdays)#{@at}#{@loose_time}#{@what}/isu,
       &recurring(&1, &2, "1-5", "every weekday")},
      {~r/^(?:every\s+weekend|weekends)#{@at}#{@loose_time}#{@what}/isu,
       &recurring(&1, &2, "0,6", "every weekend")},
      {~r/^every\s+(?<day>#{@day_names})s?(?![a-z])#{@at}#{@loose_time}#{@what}/isu,
       &day_of_week/2},
      {~r/^every\s+(?<n>\d+)\s*(?<unit>#{@minute_units}|#{@hour_units})(?![a-z])#{@what}/isu,
       &interval/2},
      {~r/^(?:every\s+hour|hourly)#{@what}/isu, &hourly/2},
      {~r/^at\s+#{@loose_time}#{@what}/isu, &clock/2},
      {~r/^#{@strict_time}#{@what}/isu, &clock/2}
    ]
  end

  # --- builders -------------------------------------------------------------

  defp relative(%{"dur" => dur, "what" => what}, now) do
    seconds =
      Regex.scan(~r/(\d+)\s*([a-z]+)/i, dur, capture: :all_but_first)
      |> Enum.map(fn [n, unit] -> String.to_integer(n) * unit_seconds(unit) end)
      |> Enum.sum()

    cond do
      seconds <= 0 ->
        error("The delay must be greater than zero.")

      seconds > @max_relative_minutes * 60 ->
        error("Relative reminders can be at most 364 days ahead.")

      true ->
        target = now |> NaiveDateTime.add(seconds, :second) |> round_up_to_minute()
        one_shot(target, what)
    end
  end

  defp tomorrow(%{"time" => time, "what" => what}, now) do
    with {:ok, {hour, minute}} <- parse_time(time) do
      date = now |> NaiveDateTime.to_date() |> Date.add(1)
      one_shot(NaiveDateTime.new!(date, Time.new!(hour, minute, 0)), what)
    end
  end

  defp clock(%{"time" => time, "what" => what}, now) do
    with {:ok, {hour, minute}} <- parse_time(time) do
      today = NaiveDateTime.new!(NaiveDateTime.to_date(now), Time.new!(hour, minute, 0))

      target =
        if NaiveDateTime.compare(today, now) == :gt,
          do: today,
          else: NaiveDateTime.add(today, 86_400, :second)

      one_shot(target, what)
    end
  end

  defp recurring(%{"time" => time, "what" => what}, _now, dow, label) do
    with {:ok, {hour, minute}} <- parse_time(time) do
      ok("#{minute} #{hour} * * #{dow}", false, "#{label} at #{hm(hour, minute)}", what)
    end
  end

  defp day_of_week(%{"day" => day} = captures, now) do
    {dow, name} = Map.fetch!(@dow, day |> String.downcase() |> String.slice(0, 3))
    recurring(captures, now, Integer.to_string(dow), "every #{name}")
  end

  defp interval(%{"n" => n, "unit" => unit, "what" => what}, _now) do
    n = String.to_integer(n)

    if unit_seconds(unit) == 60 do
      minute_interval(n, what)
    else
      hour_interval(n, what)
    end
  end

  defp hourly(%{"what" => what}, _now), do: ok("0 * * * *", false, "every hour", what)

  defp minute_interval(1, what), do: ok("* * * * *", false, "every minute", what)
  defp minute_interval(60, what), do: ok("0 * * * *", false, "every hour", what)

  defp minute_interval(n, what) when n > 1 and n < 60 and rem(60, n) == 0,
    do: ok("*/#{n} * * * *", false, "every #{n} minutes", what)

  defp minute_interval(n, _what) do
    error(
      "Every #{n} minutes does not divide an hour evenly; " <>
        "use one of 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60."
    )
  end

  defp hour_interval(1, what), do: ok("0 * * * *", false, "every hour", what)
  defp hour_interval(24, what), do: ok("0 0 * * *", false, "every day at 00:00", what)

  defp hour_interval(n, what) when n > 1 and n < 24 and rem(24, n) == 0,
    do: ok("0 */#{n} * * *", false, "every #{n} hours", what)

  defp hour_interval(n, _what) do
    error("Every #{n} hours does not divide a day evenly; use one of 1, 2, 3, 4, 6, 8, 12, 24.")
  end

  # --- helpers --------------------------------------------------------------

  defp one_shot(%NaiveDateTime{} = target, what) do
    ok(
      "#{target.minute} #{target.hour} #{target.day} #{target.month} *",
      true,
      "once at #{format_naive(target)}",
      what
    )
  end

  defp ok(schedule, once, description, what) do
    case String.trim(what) do
      "" -> error("Say what to remind you about.")
      text -> {:ok, %{schedule: schedule, once: once, description: description, text: text}}
    end
  end

  defp error(message), do: {:error, message <> "\n\n" <> usage()}

  defp parse_time(raw) do
    normalized = raw |> String.downcase() |> String.replace(~r/\s+/u, "")

    case normalized do
      "noon" ->
        {:ok, {12, 0}}

      "midnight" ->
        {:ok, {0, 0}}

      _ ->
        %{"h" => h, "m" => m, "ampm" => ampm} =
          Regex.named_captures(~r/^(?<h>\d{1,2})(?::(?<m>\d{2}))?(?<ampm>am|pm)?$/, normalized)

        hour = String.to_integer(h)
        minute = if m == "", do: 0, else: String.to_integer(m)

        case to_24h(hour, ampm) do
          {:ok, hour24} when minute in 0..59 -> {:ok, {hour24, minute}}
          _ -> error("Invalid time \"#{String.trim(raw)}\".")
        end
    end
  end

  defp to_24h(hour, ""), do: if(hour in 0..23, do: {:ok, hour}, else: :error)
  defp to_24h(12, "am"), do: {:ok, 0}
  defp to_24h(12, "pm"), do: {:ok, 12}
  defp to_24h(hour, "am") when hour in 1..11, do: {:ok, hour}
  defp to_24h(hour, "pm") when hour in 1..11, do: {:ok, hour + 12}
  defp to_24h(_hour, _ampm), do: :error

  defp unit_seconds(unit) do
    case String.downcase(unit) do
      "d" <> _ -> 86_400
      "h" <> _ -> 3_600
      "m" <> _ -> 60
    end
  end

  defp round_up_to_minute(%NaiveDateTime{second: 0, microsecond: {0, _}} = dt),
    do: NaiveDateTime.truncate(dt, :second)

  defp round_up_to_minute(%NaiveDateTime{} = dt) do
    %{dt | second: 0, microsecond: {0, 0}}
    |> NaiveDateTime.add(60, :second)
    |> NaiveDateTime.truncate(:second)
  end

  @doc false
  @spec format_naive(NaiveDateTime.t()) :: String.t()
  def format_naive(%NaiveDateTime{} = dt) do
    abbr = Enum.at(@weekday_abbr, Date.day_of_week(dt) - 1)

    "#{abbr} #{dt.year}-#{pad(dt.month)}-#{pad(dt.day)} #{hm(dt.hour, dt.minute)}"
  end

  defp hm(hour, minute), do: "#{pad(hour)}:#{pad(minute)}"
  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
