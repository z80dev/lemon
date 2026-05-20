defmodule LemonAutomation.CronSchedule do
  @moduledoc """
  Cron expression parsing and next-run computation.

  Supports standard 5-field cron expressions and a small set of operator
  shorthands that normalize to 5-field cron before validation:

  ```
  * * * * *
  | | | | |
  | | | | +-- Day of week (0-7, Sunday = 0 or 7)
  | | | +---- Month (1-12)
  | | +------ Day of month (1-31)
  | +-------- Hour (0-23)
  +---------- Minute (0-59)
  ```

  ## Supported Syntax

  - `*` - Every value
  - `N` - Specific value (e.g., `5`)
  - `N-M` - Range (e.g., `1-5`)
  - `*/N` - Step (e.g., `*/15` for every 15)
  - `N,M,O` - List (e.g., `1,15,30`)
  - `every 30m`, `15 minutes` - Minute intervals that divide one hour
  - `hourly`, `every 2h` - Hour intervals that divide one day
  - `daily at 9am`, `weekdays at 09:30`, `weekly monday at 8am`

  ## Examples

      # Parse a schedule
      {:ok, parsed} = CronSchedule.parse("0 9 * * *")

      # Get next run time in milliseconds
      next_ms = CronSchedule.next_run_ms("0 9 * * *", "UTC")

      # Get next N run times
      times = CronSchedule.next_runs("*/15 * * * *", "UTC", count: 5)
  """

  @type parsed :: %{
          minute: [non_neg_integer()],
          hour: [non_neg_integer()],
          day: [non_neg_integer()],
          month: [non_neg_integer()],
          weekday: [non_neg_integer()]
        }

  @minute_range 0..59
  @hour_range 0..23
  @day_range 1..31
  @month_range 1..12
  # Allow 0-7 for weekday (both 0 and 7 mean Sunday), then normalize
  @weekday_range 0..7
  @day_names %{
    "sun" => 0,
    "sunday" => 0,
    "mon" => 1,
    "monday" => 1,
    "tue" => 2,
    "tuesday" => 2,
    "wed" => 3,
    "wednesday" => 3,
    "thu" => 4,
    "thursday" => 4,
    "fri" => 5,
    "friday" => 5,
    "sat" => 6,
    "saturday" => 6
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Normalize a supported schedule shorthand to a 5-field cron expression.

  Supported shorthands include interval forms such as `every 30m`, `every 2h`,
  `hourly`, `daily at 9am`, `weekdays at 09:30`, and `weekly monday at 8am`.
  Unknown input is returned trimmed so normal cron validation can report the
  field-level error.
  """
  @spec normalize(binary()) :: {:ok, binary()} | {:error, binary()}
  def normalize(expression) when is_binary(expression) do
    expression = String.trim(expression)

    cond do
      expression == "" ->
        {:error, "Schedule cannot be empty"}

      cron_expression?(expression) ->
        {:ok, expression}

      true ->
        case normalize_shorthand(expression) do
          {:error, reason} -> {:error, reason}
          normalized -> {:ok, normalized}
        end
    end
  end

  @doc """
  Parse a cron expression into a structured format.

  Returns `{:ok, parsed}` or `{:error, reason}`.
  """
  @spec parse(binary()) :: {:ok, parsed()} | {:error, binary()}
  def parse(expression) when is_binary(expression) do
    with {:ok, expression} <- normalize(expression) do
      parts = String.split(expression, ~r/\s+/, trim: true)

      case parts do
        [minute, hour, day, month, weekday] ->
          with {:ok, minute_vals} <- parse_field(minute, @minute_range, "minute"),
               {:ok, hour_vals} <- parse_field(hour, @hour_range, "hour"),
               {:ok, day_vals} <- parse_field(day, @day_range, "day"),
               {:ok, month_vals} <- parse_field(month, @month_range, "month"),
               {:ok, weekday_vals} <- parse_field(weekday, @weekday_range, "weekday") do
            {:ok,
             %{
               minute: minute_vals,
               hour: hour_vals,
               day: day_vals,
               month: month_vals,
               weekday: normalize_weekdays(weekday_vals)
             }}
          end

        _ ->
          {:error, "Expected 5 fields (minute hour day month weekday), got #{length(parts)}"}
      end
    end
  end

  @doc """
  Compute the next run time in milliseconds from now.

  Returns the timestamp in milliseconds, or nil if unable to compute.
  """
  @spec next_run_ms(binary(), binary()) :: non_neg_integer() | nil
  def next_run_ms(expression, timezone \\ "UTC") do
    case next_run_datetime(expression, timezone) do
      nil -> nil
      datetime -> DateTime.to_unix(datetime, :millisecond)
    end
  end

  @doc """
  Compute the next run time as a DateTime.
  """
  @spec next_run_datetime(binary(), binary()) :: DateTime.t() | nil
  def next_run_datetime(expression, timezone \\ "UTC") do
    case parse(expression) do
      {:ok, parsed} ->
        now = now_in_timezone(timezone)
        find_next_run(parsed, now, 0)

      {:error, _} ->
        nil
    end
  end

  @doc """
  Compute multiple future run times.

  ## Options

  - `:count` - Number of future times to compute (default: 5)
  - `:from` - Starting DateTime (default: now)
  """
  @spec next_runs(binary(), binary(), keyword()) :: [DateTime.t()]
  def next_runs(expression, timezone \\ "UTC", opts \\ []) do
    count = Keyword.get(opts, :count, 5)

    case parse(expression) do
      {:ok, parsed} ->
        now = now_in_timezone(timezone)
        collect_next_runs(parsed, now, count, [])

      {:error, _} ->
        []
    end
  end

  @doc """
  Check if a DateTime matches a cron expression.
  """
  @spec matches?(binary(), DateTime.t()) :: boolean()
  def matches?(expression, datetime) do
    case parse(expression) do
      {:ok, parsed} ->
        datetime.minute in parsed.minute and
          datetime.hour in parsed.hour and
          datetime.day in parsed.day and
          datetime.month in parsed.month and
          day_of_week(datetime) in parsed.weekday

      {:error, _} ->
        false
    end
  end

  @doc """
  Validate a cron expression without computing next run.
  """
  @spec valid?(binary()) :: boolean()
  def valid?(expression) do
    case parse(expression) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  # ============================================================================
  # Field Parsing
  # ============================================================================

  defp cron_expression?(expression) do
    expression |> String.split(~r/\s+/, trim: true) |> length() == 5
  end

  defp normalize_shorthand(expression) do
    normalized =
      expression
      |> String.downcase()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      normalized in ["hourly", "every hour"] ->
        "0 * * * *"

      normalized in ["daily", "every day"] ->
        "0 9 * * *"

      normalized in ["weekdays", "every weekday"] ->
        "0 9 * * 1-5"

      normalized in ["weekly", "every week"] ->
        "0 9 * * 1"

      match = Regex.run(~r/^every\s+(\d+)\s*(m|min|mins|minute|minutes)$/, normalized) ->
        every_minutes(match)

      match = Regex.run(~r/^(\d+)\s*(m|min|mins|minute|minutes)$/, normalized) ->
        every_minutes(match)

      match = Regex.run(~r/^every\s+(\d+)\s*(h|hr|hrs|hour|hours)$/, normalized) ->
        every_hours(match)

      match = Regex.run(~r/^(\d+)\s*(h|hr|hrs|hour|hours)$/, normalized) ->
        every_hours(match)

      match = Regex.run(~r/^(daily|every day)\s+(?:at\s+)?(.+)$/, normalized) ->
        at_daily(match)

      match = Regex.run(~r/^(weekdays|every weekday)\s+(?:at\s+)?(.+)$/, normalized) ->
        at_weekdays(match)

      match = Regex.run(~r/^weekly\s+([a-z]+)\s+(?:at\s+)?(.+)$/, normalized) ->
        at_weekly(match)

      match = Regex.run(~r/^every\s+([a-z]+)\s+(?:at\s+)?(.+)$/, normalized) ->
        at_weekly(match)

      match = Regex.run(~r/^([a-z]+)s\s+(?:at\s+)?(.+)$/, normalized) ->
        at_weekly(match)

      true ->
        expression
    end
  end

  defp every_minutes([_, value | _]) do
    case Integer.parse(value) do
      {60, ""} ->
        "0 * * * *"

      {minutes, ""} when minutes in 1..59 and rem(60, minutes) == 0 ->
        "*/#{minutes} * * * *"

      {minutes, ""} when minutes > 0 ->
        {:error, "Minute interval must evenly divide 60"}

      _ ->
        value
    end
  end

  defp every_hours([_, value | _]) do
    case Integer.parse(value) do
      {24, ""} ->
        "0 0 * * *"

      {hours, ""} when hours in 1..23 and rem(24, hours) == 0 ->
        "0 */#{hours} * * *"

      {hours, ""} when hours > 0 ->
        {:error, "Hour interval must evenly divide 24"}

      _ ->
        value
    end
  end

  defp at_daily([_, prefix, time]) do
    case parse_time(time) do
      {:ok, hour, minute} -> "#{minute} #{hour} * * *"
      :error -> "#{prefix} #{time}"
    end
  end

  defp at_weekdays([_, prefix, time]) do
    case parse_time(time) do
      {:ok, hour, minute} -> "#{minute} #{hour} * * 1-5"
      :error -> "#{prefix} #{time}"
    end
  end

  defp at_weekly([_, day, time]) do
    with {:ok, hour, minute} <- parse_time(time),
         weekday when is_integer(weekday) <- Map.get(@day_names, day) do
      "#{minute} #{hour} * * #{weekday}"
    else
      _ -> "#{day} #{time}"
    end
  end

  defp parse_time(time) do
    time = String.trim(time)

    cond do
      match = Regex.run(~r/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/, time) ->
        parse_ampm_time(match)

      match = Regex.run(~r/^(\d{1,2}):(\d{2})$/, time) ->
        parse_24h_time(match)

      match = Regex.run(~r/^(\d{1,2})$/, time) ->
        parse_24h_time([nil, Enum.at(match, 1), "0"])

      true ->
        :error
    end
  end

  defp parse_ampm_time([_, hour_str, minute_str, suffix]) do
    minute_str = if minute_str in [nil, ""], do: "0", else: minute_str

    with {hour, ""} <- Integer.parse(hour_str),
         {minute, ""} <- Integer.parse(minute_str),
         true <- hour in 1..12 and minute in 0..59 do
      hour =
        case {hour, suffix} do
          {12, "am"} -> 0
          {12, "pm"} -> 12
          {hour, "pm"} -> hour + 12
          {hour, "am"} -> hour
        end

      {:ok, hour, minute}
    else
      _ -> :error
    end
  end

  defp parse_24h_time([_, hour_str, minute_str]) do
    with {hour, ""} <- Integer.parse(hour_str),
         {minute, ""} <- Integer.parse(minute_str),
         true <- hour in 0..23 and minute in 0..59 do
      {:ok, hour, minute}
    else
      _ -> :error
    end
  end

  defp parse_field("*", range, _field_name) do
    {:ok, Enum.to_list(range)}
  end

  defp parse_field("*/0", _range, field_name) do
    {:error, "Invalid step 0 in #{field_name}"}
  end

  defp parse_field("*/" <> step_str, range, field_name) do
    case Integer.parse(step_str) do
      {step, ""} when step > 0 ->
        values = range |> Enum.take_every(step) |> Enum.to_list()
        {:ok, values}

      _ ->
        {:error, "Invalid step value in #{field_name}: #{step_str}"}
    end
  end

  defp parse_field(field, range, field_name) do
    cond do
      String.contains?(field, ",") ->
        parse_list(field, range, field_name)

      String.contains?(field, "-") ->
        parse_range(field, range, field_name)

      true ->
        parse_single(field, range, field_name)
    end
  end

  defp parse_single(value_str, min..max//_, field_name) do
    case Integer.parse(value_str) do
      {value, ""} when value >= min and value <= max ->
        {:ok, [value]}

      {value, ""} ->
        {:error, "Value #{value} out of range #{min}-#{max} in #{field_name}"}

      _ ->
        {:error, "Invalid value in #{field_name}: #{value_str}"}
    end
  end

  defp parse_range(field, min..max//_, field_name) do
    case String.split(field, "-") do
      [start_str, end_str] ->
        with {start_val, ""} <- Integer.parse(start_str),
             {end_val, ""} <- Integer.parse(end_str),
             true <- start_val >= min and end_val <= max and start_val <= end_val do
          {:ok, Enum.to_list(start_val..end_val)}
        else
          _ -> {:error, "Invalid range in #{field_name}: #{field}"}
        end

      _ ->
        {:error, "Invalid range format in #{field_name}: #{field}"}
    end
  end

  defp parse_list(field, range, field_name) do
    parts = String.split(field, ",")

    results =
      Enum.map(parts, fn part ->
        cond do
          String.contains?(part, "-") -> parse_range(part, range, field_name)
          true -> parse_single(part, range, field_name)
        end
      end)

    case Enum.find(results, fn r -> match?({:error, _}, r) end) do
      {:error, _} = error ->
        error

      nil ->
        values =
          results
          |> Enum.flat_map(fn {:ok, vals} -> vals end)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, values}
    end
  end

  # Normalize weekday 7 (Sunday) to 0
  defp normalize_weekdays(weekdays) do
    weekdays
    |> Enum.map(fn
      7 -> 0
      d -> d
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ============================================================================
  # Next Run Computation
  # ============================================================================

  @max_iterations 366 * 24 * 60

  defp find_next_run(_parsed, _datetime, iterations) when iterations > @max_iterations do
    nil
  end

  defp find_next_run(parsed, datetime, iterations) do
    # Move to next minute
    candidate = DateTime.add(datetime, 1, :minute) |> truncate_to_minute()

    if matches_parsed?(parsed, candidate) do
      candidate
    else
      find_next_run(parsed, candidate, iterations + 1)
    end
  end

  defp collect_next_runs(_parsed, _from, 0, acc), do: Enum.reverse(acc)

  defp collect_next_runs(parsed, from, count, acc) do
    case find_next_run(parsed, from, 0) do
      nil ->
        Enum.reverse(acc)

      next ->
        collect_next_runs(parsed, next, count - 1, [next | acc])
    end
  end

  defp matches_parsed?(parsed, datetime) do
    datetime.minute in parsed.minute and
      datetime.hour in parsed.hour and
      datetime.day in parsed.day and
      datetime.month in parsed.month and
      day_of_week(datetime) in parsed.weekday
  end

  defp truncate_to_minute(datetime) do
    %{datetime | second: 0, microsecond: {0, 0}}
  end

  defp day_of_week(datetime) do
    Date.day_of_week(datetime) |> rem(7)
  end

  defp now_in_timezone("UTC") do
    DateTime.utc_now()
  end

  defp now_in_timezone(timezone) do
    case DateTime.now(timezone) do
      {:ok, dt} -> dt
      {:error, _} -> DateTime.utc_now()
    end
  end
end
