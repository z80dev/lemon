defmodule LemonAutomation.Env do
  @moduledoc """
  Environment variables read by `lemon_automation` — cron and goal-loop automation.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :lemon_goal_judge_model,
      env_var: "LEMON_GOAL_JUDGE_MODEL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Model id used to judge automation goal completion.",
      secret?: false,
      required?: false,
      area: :arena,
      apps: [:lemon_automation]
    },
    %{
      name: :lemon_cron_preflight_enabled,
      env_var: "LEMON_CRON_PREFLIGHT_ENABLED",
      aliases: [],
      type: :boolean,
      default: nil,
      doc: "Override the cron pre-dispatch preflight (provider/target readiness) toggle.",
      secret?: false,
      required?: false,
      area: :automation,
      apps: [:lemon_automation]
    },
    %{
      name: :lemon_cron_drift_guard_enabled,
      env_var: "LEMON_CRON_DRIFT_GUARD_ENABLED",
      aliases: [],
      type: :boolean,
      default: nil,
      doc:
        "Override the cron model drift guard (fail closed when the global default model changed under an unpinned job).",
      secret?: false,
      required?: false,
      area: :automation,
      apps: [:lemon_automation]
    }
  ]
end
