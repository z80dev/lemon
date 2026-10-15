defmodule LemonCore.Config.Automation do
  @moduledoc """
  Proactive automation settings under `[automation]`.

      [automation]
      daily_brief = "08:00"

  `daily_brief` is the server-local wall-clock time (`HH:MM`, 24-hour) of an
  opt-in morning brief. When set, `LemonAutomation` keeps one heartbeat cron
  job in sync with it at boot; removing the key removes the job. `lemon setup`
  offers to write it. Absent (the default) means no daily brief.
  """

  defstruct daily_brief: nil, catch_up_missed: true, run_retention_per_job: 100

  @type t :: %__MODULE__{
          daily_brief: String.t() | nil,
          catch_up_missed: boolean(),
          run_retention_per_job: non_neg_integer()
        }

  @time_pattern ~r/^([01]?\d|2[0-3]):([0-5]\d)$/

  @doc "Resolves the `[automation]` section."
  @spec resolve(map()) :: t()
  def resolve(settings) when is_map(settings) do
    section =
      case settings["automation"] do
        section when is_map(section) -> section
        _ -> %{}
      end

    %__MODULE__{
      daily_brief: normalize_time(section["daily_brief"]),
      catch_up_missed: Map.get(section, "catch_up_missed", true),
      run_retention_per_job: Map.get(section, "run_retention_per_job", 100)
    }
  end

  @doc """
  Parses a `HH:MM` 24-hour time into `{hour, minute}`.
  """
  @spec parse_time(term()) :: {:ok, {0..23, 0..59}} | :error
  def parse_time(value) when is_binary(value) do
    case Regex.run(@time_pattern, String.trim(value)) do
      [_, hour, minute] -> {:ok, {String.to_integer(hour), String.to_integer(minute)}}
      _ -> :error
    end
  end

  def parse_time(_value), do: :error

  @doc "Validates the resolved section, prepending `automation.*` errors."
  @spec validate(t(), [String.t()]) :: [String.t()]
  def validate(%__MODULE__{} = config, errors) do
    errors =
      if is_nil(config.daily_brief) or match?({:ok, _}, parse_time(config.daily_brief)),
        do: errors,
        else: ["automation.daily_brief: must be a HH:MM 24-hour time" | errors]

    errors =
      if is_boolean(config.catch_up_missed),
        do: errors,
        else: ["automation.catch_up_missed: must be a boolean" | errors]

    if is_integer(config.run_retention_per_job) and config.run_retention_per_job >= 0,
      do: errors,
      else: ["automation.run_retention_per_job: must be a non-negative integer" | errors]
  end

  defp normalize_time(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_time(_value), do: nil
end
