defmodule LemonRouter.ModelSelection do
  @moduledoc """
  Resolves model selection independently from execution routing.

  Precedence (highest to lowest):

  request-level explicit model -> meta model -> session model -> profile model ->
  routing-feedback history model -> router default model

  The `history_model` slot is populated by the router when the `routing_feedback`
  feature flag is enabled and sufficient historical performance data exists for the
  task context. It acts as a soft tie-breaker between the profile default and the
  router fallback — it never overrides explicit user intent.
  """

  @type t :: %{model: String.t() | nil}

  @spec resolve(map()) :: t()
  def resolve(input) when is_map(input) do
    resolved_model =
      normalize_string(input[:explicit_model]) ||
        normalize_string(input[:meta_model]) ||
        normalize_string(input[:session_model]) ||
        normalize_string(input[:profile_model]) ||
        normalize_string(input[:history_model]) ||
        normalize_string(input[:default_model])

    %{model: resolved_model}
  end

  def resolve(_), do: %{model: nil}

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil
end
