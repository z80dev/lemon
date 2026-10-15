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
  - `in 30m`, `in 2h`, `in 1d` - Relative one-shots
  - `YYYY-MM-DDTHH:MM[:SS]` - One-shot wall-clock timestamp in the job timezone

  `prepare/3` validates that one-shots are future instants and converts them to
  absolute UTC ISO timestamps for storage. `parse/3` returns `{:once_at, ms}`
  for these schedules; `next_runs/3` returns at most one occurrence.

  ## Timezones

  `"UTC"` (the default) evaluates schedules in UTC. `"local"` evaluates them in
  the server's OS-local wall-clock time through `:calendar`. IANA names such as
  `"America/New_York"` use the configured `Calendar.TimeZoneDatabase` (Tzdata
  by default), including historical and future daylight-saving transitions.
  Invalid or unavailable zones never fall back to UTC.

  Nonexistent wall-clock slots during a spring-forward gap are skipped. A
  repeated slot during a fall-back fold runs only at its first (earliest UTC)
  occurrence; the second occurrence is skipped even when the first has passed.
  Results are strictly after the starting instant and are returned in UTC.

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
  Parse a schedule into cron fields or `{:once_at, unix_ms}`.

  Parsing alone permits past instants; use `prepare/3` for creation/update
  validation. Options include `:from` for relative delays and
  `:time_zone_database` for local ISO timestamps.
  """
  @spec parse(binary(), binary(), keyword()) ::
          {:ok, parsed() | {:once_at, integer()}} | {:error, binary()}
  def parse(expression, timezone \\ "UTC", opts \\ []) when is_binary(expression) do
    with {:ok, expression} <- normalize(expression) do
      case parse_one_shot(expression, timezone, opts) do
        :not_one_shot -> parse_cron(expression)
        result -> result
      end
    end
  end

  defp parse_cron(expression) do
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

  @doc """
  Validate a schedule for creation/update. One-shots must be in the future and
  are pinned to an absolute UTC timestamp so relative delays never move on restart.
  """
  @spec prepare(binary(), binary(), keyword()) ::
          {:ok, binary(), boolean()} | {:error, binary()}
  def prepare(expression, timezone \\ "UTC", opts \\ []) do
    with {:ok, normalized} <- normalize(expression),
         {:ok, parsed} <- parse(normalized, timezone, opts) do
      case parsed do
        {:once_at, due} ->
          prepare_one_shot(due, opts)

        _cron ->
          {:ok, normalized, false}
      end
    end
  end

  defp prepare_one_shot(due, opts) do
    from = Keyword.get_lazy(opts, :from, &DateTime.utc_now/0)

    if due <= DateTime.to_unix(from, :millisecond) do
      {:error, "One-shot timestamp must be in the future"}
    else
      case DateTime.from_unix(due, :millisecond) do
        {:ok, datetime} -> {:ok, DateTime.to_iso8601(datetime), true}
        {:error, _} -> {:error, "One-shot timestamp is outside the supported date range"}
      end
    end
  end

  defp parse_one_shot(expression, timezone, opts) do
    cond do
      match = Regex.run(~r/^in\s+(\d+)\s*([mhd])$/i, expression) ->
        [_, amount, unit] = match
        amount = String.to_integer(amount)
        seconds = %{"m" => 60, "h" => 3600, "d" => 86_400}[String.downcase(unit)]
        from = Keyword.get_lazy(opts, :from, &DateTime.utc_now/0)

        if amount > 0,
          do: {:ok, {:once_at, DateTime.to_unix(from, :millisecond) + amount * seconds * 1000}},
          else: {:error, "One-shot delay must be positive"}

      Regex.match?(~r/^\d{4}-\d{2}-\d{2}T/, expression) ->
        parse_timestamp(expression, timezone, opts)

      true ->
        :not_one_shot
    end
  end

  defp parse_timestamp(expression, timezone, opts) do
    if String.ends_with?(expression, "Z") do
      case DateTime.from_iso8601(expression) do
        {:ok, datetime, _offset} -> {:ok, {:once_at, DateTime.to_unix(datetime, :millisecond)}}
        _ -> {:error, "Invalid ISO-8601 timestamp"}
      end
    else
      parse_local_timestamp(expression, timezone, opts)
    end
  end

  defp parse_local_timestamp(expression, timezone, opts) do
    expression = if String.length(expression) == 16, do: expression <> ":00", else: expression
    database = Keyword.get(opts, :time_zone_database, Calendar.get_time_zone_database())

    with true <- Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/, expression),
         {:ok, wall} <- NaiveDateTime.from_iso8601(expression),
         {:ok, datetime} <- wall_to_utc(wall, timezone, database) do
      {:ok, {:once_at, DateTime.to_unix(datetime, :millisecond)}}
    else
      :skip -> {:error, "One-shot timestamp falls in a daylight-saving gap"}
      _ -> {:error, "Invalid ISO-8601 timestamp or timezone"}
    end
  end

  @doc """
  Compute the next run time in Unix milliseconds.

  Accepts the same options as `next_runs/3`. Returns nil for an invalid schedule,
  invalid/unavailable timezone, or no matching slot within the search horizon.
  """
  @spec next_run_ms(binary(), binary(), keyword()) :: integer() | nil
  def next_run_ms(expression, timezone \\ "UTC", opts \\ []) do
    case next_run_datetime(expression, timezone, opts) do
      nil -> nil
      datetime -> DateTime.to_unix(datetime, :millisecond)
    end
  end

  @doc """
  Compute the next run time as a UTC DateTime, strictly after `:from` (or now).

  Accepts the same options as `next_runs/3` and returns nil on failure.
  """
  @spec next_run_datetime(binary(), binary(), keyword()) :: DateTime.t() | nil
  def next_run_datetime(expression, timezone \\ "UTC", opts \\ []) do
    expression
    |> next_runs(timezone, Keyword.put(opts, :count, 1))
    |> List.first()
  end

  @doc """
  Compute multiple future run times as UTC DateTimes in chronological order.

  ## Options

  - `:count` - Number of future times to compute (default: 5)
  - `:from` - Starting DateTime instant, exclusive (default: now)
  - `:time_zone_database` - Calendar timezone database (default: configured database)

  Missing DST slots are skipped; repeated slots use only their first occurrence.
  Each search looks up to 366 calendar days ahead. Invalid schedules or
  invalid/unavailable timezones return an empty list.
  """
  @spec next_runs(binary(), binary(), keyword()) :: [DateTime.t()]
  def next_runs(expression, timezone \\ "UTC", opts \\ []) do
    count = Keyword.get(opts, :count, 5)
    from = Keyword.get_lazy(opts, :from, &DateTime.utc_now/0)
    database = Keyword.get(opts, :time_zone_database, Calendar.get_time_zone_database())

    with true <- is_integer(count) and count > 0,
         {:ok, parsed} <- parse(expression, timezone, opts),
         {:ok, date} <- source_date(from, timezone, database) do
      collect_next_runs(parsed, timezone, database, from, date, count, [])
    else
      _ -> []
    end
  end

  @doc """
  Validate a timezone without computing a schedule.

  UTC and OS-local time are always supported. Other names must resolve through
  the supplied/configured Calendar timezone database. Unknown names return
  `{:error, :invalid_timezone}`; an unavailable database returns
  `{:error, :timezone_unavailable}`.
  """
  @spec validate_timezone(term(), module()) ::
          :ok | {:error, :invalid_timezone | :timezone_unavailable}
  def validate_timezone(timezone, database \\ Calendar.get_time_zone_database()) do
    case source_date(DateTime.utc_now(), timezone, database) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a DateTime matches a cron expression.
  """
  @spec matches?(binary(), DateTime.t()) :: boolean()
  def matches?(expression, datetime) do
    case parse(expression, datetime.time_zone) do
      {:ok, {:once_at, due}} ->
        DateTime.to_unix(datetime, :millisecond) == due

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

  @max_days 366

  defp collect_next_runs(_parsed, _timezone, _database, _from, _date, 0, acc),
    do: Enum.reverse(acc)

  defp collect_next_runs({:once_at, due}, _timezone, _database, from, _date, _count, _acc) do
    with true <- due > DateTime.to_unix(from, :millisecond),
         {:ok, datetime} <- DateTime.from_unix(due, :millisecond) do
      [datetime]
    else
      _ -> []
    end
  end

  defp collect_next_runs(parsed, timezone, database, from, date, count, acc) do
    case find_next_run(parsed, timezone, database, from, date, 0) do
      {:ok, next, date} ->
        collect_next_runs(parsed, timezone, database, next, date, count - 1, [next | acc])

      _ ->
        Enum.reverse(acc)
    end
  end

  defp find_next_run(_parsed, _timezone, _database, _from, _date, days)
       when days > @max_days,
       do: nil

  defp find_next_run(parsed, timezone, database, from, date, days) do
    result =
      if date.day in parsed.day and date.month in parsed.month and
           day_of_week(date) in parsed.weekday do
        next_slot(parsed, timezone, database, from, date)
      end

    case result do
      {:ok, next} -> {:ok, next, date}
      {:error, _} = error -> error
      nil -> find_next_run(parsed, timezone, database, from, Date.add(date, 1), days + 1)
    end
  end

  # Calendar slots, not elapsed-time arithmetic: resolve each candidate against
  # its own timezone period. Always compare instants, including when :from is
  # inside the second occurrence of a repeated hour.
  defp next_slot(parsed, timezone, database, from, date) do
    Enum.reduce_while(parsed.hour, nil, fn hour, _ ->
      result =
        Enum.reduce_while(parsed.minute, nil, fn minute, _ ->
          wall = NaiveDateTime.new!(date, Time.new!(hour, minute, 0))

          case wall_to_utc(wall, timezone, database) do
            {:ok, utc} ->
              if DateTime.compare(utc, from) == :gt,
                do: {:halt, {:ok, utc}},
                else: {:cont, nil}

            :skip ->
              {:cont, nil}

            {:error, _} = error ->
              {:halt, error}
          end
        end)

      if is_nil(result), do: {:cont, nil}, else: {:halt, result}
    end)
  end

  defp source_date(from, "local", _database) do
    {date, _time} = :calendar.system_time_to_local_time(DateTime.to_unix(from), :second)
    {:ok, Date.from_erl!(date)}
  end

  defp source_date(from, timezone, database) when is_binary(timezone) do
    timezone = if timezone == "UTC", do: "Etc/UTC", else: timezone

    case DateTime.shift_zone(from, timezone, database) do
      {:ok, zoned} -> {:ok, DateTime.to_date(zoned)}
      {:error, :time_zone_not_found} -> {:error, :invalid_timezone}
      {:error, _} -> {:error, :timezone_unavailable}
    end
  rescue
    ArgumentError -> {:error, :timezone_unavailable}
  end

  defp source_date(_from, _timezone, _database), do: {:error, :invalid_timezone}

  defp wall_to_utc(wall, "local", _database) do
    case :calendar.local_time_to_universal_time_dst(NaiveDateTime.to_erl(wall)) do
      [] -> :skip
      instants -> {:ok, instants |> Enum.min() |> NaiveDateTime.from_erl!() |> utc_from_naive()}
    end
  end

  defp wall_to_utc(wall, timezone, database) do
    timezone = if timezone == "UTC", do: "Etc/UTC", else: timezone

    case DateTime.from_naive(wall, timezone, database) do
      {:ok, zoned} -> {:ok, utc(zoned)}
      {:ambiguous, first, _second} -> {:ok, utc(first)}
      {:gap, _before, _after} -> :skip
      {:error, :time_zone_not_found} -> {:error, :invalid_timezone}
      {:error, _} -> {:error, :timezone_unavailable}
    end
  rescue
    ArgumentError -> {:error, :timezone_unavailable}
  end

  defp utc_from_naive(wall),
    do: DateTime.from_naive!(wall, "Etc/UTC", Calendar.UTCOnlyTimeZoneDatabase)

  defp utc(datetime),
    do: DateTime.shift_zone!(datetime, "Etc/UTC", Calendar.UTCOnlyTimeZoneDatabase)

  defp day_of_week(datetime) do
    Date.day_of_week(datetime) |> rem(7)
  end
end
