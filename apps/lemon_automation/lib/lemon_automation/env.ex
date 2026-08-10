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
    }
  ]
end
