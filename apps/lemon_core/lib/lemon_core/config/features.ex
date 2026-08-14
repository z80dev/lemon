defmodule LemonCore.Config.Features do
  @moduledoc """
  Feature flag configuration for Lemon.

  Feature flags gate behaviour changes behind config so later milestones can be
  rolled out incrementally without ad-hoc environment variables.

  ## Configuration

      [features]
      session_search             = "default-on" # disable with "off"
      routing_feedback           = "default-on" # disable with "off"
      skill_synthesis_drafts     = "default-on" # disable with "off"

  All three flags ship enabled by default; each is an operator kill switch:

      export LEMON_FEATURE_ROUTING_FEEDBACK=off
      export LEMON_FEATURE_SKILL_SYNTHESIS_DRAFTS=off

  (These two were previously `"opt-in"` behind a quantitative graduation gate,
  `LemonRouter.RolloutGate`; the gate machinery was removed 2026-08-14 when
  both features were promoted to `"default-on"` by decision rather than by
  threshold.)

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
  Every shipped flag defaults to `"default-on"`; the fastest rollback is:

      export LEMON_FEATURE_SESSION_SEARCH=off
      export LEMON_FEATURE_ROUTING_FEEDBACK=off
      export LEMON_FEATURE_SKILL_SYNTHESIS_DRAFTS=off

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

  defstruct session_search: :"default-on",
            routing_feedback: :"default-on",
            skill_synthesis_drafts: :"default-on"

  @type rollout_state :: :off | :"opt-in" | :"default-on"

  @type t :: %__MODULE__{
          session_search: rollout_state(),
          routing_feedback: rollout_state(),
          skill_synthesis_drafts: rollout_state()
        }

  @doc """
  Resolves feature flags from the merged TOML settings map.

  Priority: environment variables > `[features]` TOML section > per-flag defaults
  (all three flags are `:"default-on"`).
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
          [
            "features.#{flag}: invalid state #{inspect(value)}. Valid: #{Enum.join(@valid_states, ", ")}"
          ]
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

  # All flags are enabled by default (LEMON_FEATURE_<FLAG>=off is the kill
  # switch). "opt-in" remains a valid, parseable state for configs that still
  # carry it, but nothing defaults to it.
  defp default_state("session_search"), do: :"default-on"
  defp default_state("routing_feedback"), do: :"default-on"
  defp default_state("skill_synthesis_drafts"), do: :"default-on"
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
