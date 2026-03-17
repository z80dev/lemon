defmodule LemonCore.Config.Features do
  @moduledoc """
  Feature flag configuration for Lemon.

  Feature flags gate behaviour changes behind config so later milestones can be
  rolled out incrementally without ad-hoc environment variables.

  ## Configuration

      [features]
      session_search             = "off"
      routing_feedback           = "opt-in"     # enable with "default-on" once gate passes
      skill_synthesis_drafts     = "opt-in"     # enable with "default-on" once gate passes

  ## Adaptive feature rollout

  `routing_feedback` and `skill_synthesis_drafts` are gated by measurable
  criteria defined in `LemonCore.RolloutGate`.  Both flags default to `"opt-in"`
  (available but inactive) until the quantitative gates pass:

  - **routing_feedback**: requires ≥50 recorded samples, ≥+5pp success-rate
    improvement over baseline, and no increase in retry rate.
  - **skill_synthesis_drafts**: requires ≥20 candidate documents evaluated,
    ≥60% generation rate, and ≤10% audit false-positive rate.

  To check whether a feature is ready to graduate to `"default-on"`, call
  `LemonCore.RolloutGate.evaluate_routing_feedback/1` or
  `LemonCore.RolloutGate.evaluate_synthesis/1` with a current metrics snapshot.

  To roll back a graduated feature immediately (no restart required for env vars):

      export LEMON_FEATURE_ROUTING_FEEDBACK=off
      export LEMON_FEATURE_SKILL_SYNTHESIS_DRAFTS=off

  See `LemonCore.RolloutGate` for full rollback and re-evaluation procedure.

  ## Rollout states

  | State        | Meaning |
  |---|---|
  | `"off"`      | Feature is fully disabled (kill-switch). |
  | `"opt-in"`   | Feature is available but disabled by default; must be explicitly enabled. |
  | `"default-on"` | Feature is enabled unless explicitly disabled. |
  | `"on"`       | Alias for `"default-on"`. |

  ## Environment variable overrides

  Each flag can be overridden via an environment variable using the pattern
  `LEMON_FEATURE_<FLAG_NAME>` where `<FLAG_NAME>` is the flag key in
  SCREAMING_SNAKE_CASE.

  For example:

      LEMON_FEATURE_SESSION_SEARCH=opt-in
      LEMON_FEATURE_ROUTING_FEEDBACK=default-on

  ## Kill-switch behaviour

  Set any flag to `"off"` to disable the feature regardless of code state.
  Code gated behind a flag must call `LemonCore.Config.Features.enabled?/2`
  (or the equivalent convenience helpers in `LemonCore.Config.Modular`) before
  activating that behaviour.
  """

  alias LemonCore.Config.Helpers

  @valid_states ~w[off opt-in default-on on]

  @flags ~w[
    session_search
    routing_feedback
    skill_synthesis_drafts
  ]

  defstruct session_search: :off,
            routing_feedback: :"opt-in",
            skill_synthesis_drafts: :"opt-in"

  @type rollout_state :: :off | :"opt-in" | :"default-on"

  @type t :: %__MODULE__{
          session_search: rollout_state(),
          routing_feedback: rollout_state(),
          skill_synthesis_drafts: rollout_state()
        }

  @doc """
  Resolves feature flags from the merged TOML settings map.

  Priority: environment variables > `[features]` TOML section > defaults (all `:off`).
  """
  @spec resolve(map()) :: t()
  def resolve(settings) do
    features = ensure_map(settings["features"])

    %__MODULE__{
      session_search: resolve_flag("session_search", features),
      routing_feedback: resolve_flag("routing_feedback", features),
      skill_synthesis_drafts: resolve_flag("skill_synthesis_drafts", features)
    }
  end

  @doc """
  Returns `true` when the feature is active (state is `:default-on` or `:on`).

  Pass an optional `opt_in: true` keyword to also accept the `:"opt-in"` state
  (used when the caller explicitly wants to enable an opt-in feature).

      Features.enabled?(features, :session_search)
      Features.enabled?(features, :session_search, opt_in: true)
  """
  @spec enabled?(t(), atom(), keyword()) :: boolean()
  def enabled?(%__MODULE__{} = features, flag, opts \\ []) when is_atom(flag) do
    state = Map.get(features, flag, :off)
    opt_in_allowed = Keyword.get(opts, :opt_in, false)

    case state do
      :"default-on" -> true
      :on -> true
      :"opt-in" -> opt_in_allowed
      :off -> false
      _ -> false
    end
  end

  @doc """
  Returns all known feature flag names as a list of strings.
  """
  @spec flag_names() :: [String.t()]
  def flag_names, do: @flags

  @doc """
  Validates that all feature flag values are recognised rollout states.

  Returns `:ok` or `{:error, [error_message]}`.
  """
  @spec validate(t()) :: :ok | {:error, [String.t()]}
  def validate(%__MODULE__{} = features) do
    errors =
      Enum.flat_map(@flags, fn flag ->
        value = Map.get(features, String.to_atom(flag), :off)

        if valid_state?(value) do
          []
        else
          ["features.#{flag}: invalid state #{inspect(value)}. Valid: #{Enum.join(@valid_states, ", ")}"]
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp resolve_flag(name, toml_features) do
    env_key = "LEMON_FEATURE_#{String.upcase(name)}"
    toml_value = toml_features[name]

    raw =
      case Helpers.get_env(env_key) do
        nil -> toml_value
        env_val -> env_val
      end

    if raw == nil, do: default_state(name), else: parse_state(raw)
  end

  # Adaptive features are opt-in by default; all others default to off.
  defp default_state("routing_feedback"), do: :"opt-in"
  defp default_state("skill_synthesis_drafts"), do: :"opt-in"
  defp default_state(_), do: :off

  defp parse_state("off"), do: :off
  defp parse_state(:off), do: :off
  defp parse_state("opt-in"), do: :"opt-in"
  defp parse_state(:"opt-in"), do: :"opt-in"
  defp parse_state("default-on"), do: :"default-on"
  defp parse_state(:"default-on"), do: :"default-on"
  defp parse_state("on"), do: :"default-on"
  defp parse_state(:on), do: :"default-on"
  defp parse_state(_), do: :off

  defp valid_state?(:off), do: true
  defp valid_state?(:"opt-in"), do: true
  defp valid_state?(:"default-on"), do: true
  defp valid_state?(_), do: false

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}
end
