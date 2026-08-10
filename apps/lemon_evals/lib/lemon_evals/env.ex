defmodule LemonEvals.Env do
  @moduledoc """
  Environment variables read by `lemon_evals` — the evaluation harness.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :lemon_eval_api_key,
      env_var: "LEMON_EVAL_API_KEY",
      aliases: ["INTEGRATION_API_KEY", "ANTHROPIC_API_KEY"],
      type: :string,
      default: nil,
      doc: "Live-eval provider API key.",
      secret?: true,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_api_key_secret,
      env_var: "LEMON_EVAL_API_KEY_SECRET",
      aliases: ["INTEGRATION_API_KEY_SECRET"],
      type: :string,
      default: nil,
      doc: "Secrets-store key name resolving to the live-eval API key.",
      secret?: true,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_api_type,
      env_var: "LEMON_EVAL_API_TYPE",
      aliases: ["INTEGRATION_API_TYPE"],
      type: :string,
      default: nil,
      doc: "Live-eval `Ai.Types.Model.api` atom override (default: anthropic_messages).",
      secret?: false,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_base_url,
      env_var: "LEMON_EVAL_BASE_URL",
      aliases: ["INTEGRATION_BASE_URL"],
      type: :string,
      default: nil,
      doc: "Live-eval API base URL override.",
      secret?: false,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_model,
      env_var: "LEMON_EVAL_MODEL",
      aliases: ["INTEGRATION_MODEL"],
      type: :string,
      default: nil,
      doc: "Live-eval model id (default: kimi-for-coding).",
      secret?: false,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    },
    %{
      name: :lemon_eval_provider,
      env_var: "LEMON_EVAL_PROVIDER",
      aliases: ["INTEGRATION_PROVIDER"],
      type: :string,
      default: nil,
      doc: "Live-eval provider atom override (default: kimi).",
      secret?: false,
      required?: false,
      area: :evals_live,
      apps: [:lemon_evals]
    }
  ]
end
