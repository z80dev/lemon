defmodule LemonCore.Config.Automation do
  @moduledoc """
  Cron settings under `[automation]` and cron alert policy under `[cron]`.

      [automation]
      catch_up_missed = true
      run_retention_per_job = 100

  `[cron] failure_alert_cooldown_ms` is a non-negative millisecond interval
  (default six hours). It limits repeat failure alerts per job/error class;
  zero alerts on every terminal failure.
  """

  defstruct catch_up_missed: true,
            run_retention_per_job: 100,
            failure_alert_cooldown_ms: 21_600_000

  @type t :: %__MODULE__{
          catch_up_missed: boolean(),
          run_retention_per_job: non_neg_integer(),
          failure_alert_cooldown_ms: non_neg_integer()
        }

  @doc "Resolves `[automation]` and `[cron]` alert settings."
  @spec resolve(map()) :: t()
  def resolve(settings) when is_map(settings) do
    section =
      case settings["automation"] do
        section when is_map(section) -> section
        _ -> %{}
      end

    %__MODULE__{
      catch_up_missed: Map.get(section, "catch_up_missed", true),
      run_retention_per_job: Map.get(section, "run_retention_per_job", 100),
      failure_alert_cooldown_ms:
        Map.get(settings["cron"] || %{}, "failure_alert_cooldown_ms", 21_600_000)
    }
  end

  @doc "Validates the resolved section, prepending `automation.*` errors."
  @spec validate(t(), [String.t()]) :: [String.t()]
  def validate(%__MODULE__{} = config, errors) do
    errors =
      if is_boolean(config.catch_up_missed),
        do: errors,
        else: ["automation.catch_up_missed: must be a boolean" | errors]

    errors =
      if is_integer(config.run_retention_per_job) and config.run_retention_per_job >= 0,
        do: errors,
        else: ["automation.run_retention_per_job: must be a non-negative integer" | errors]

    if is_integer(config.failure_alert_cooldown_ms) and config.failure_alert_cooldown_ms >= 0,
      do: errors,
      else: ["cron.failure_alert_cooldown_ms: must be a non-negative integer" | errors]
  end
end
