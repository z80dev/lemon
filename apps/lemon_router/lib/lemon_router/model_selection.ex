defmodule LemonRouter.ModelSelection do
  @moduledoc """
  Resolves model selection independently from execution routing.

  Precedence (highest to lowest):

  request model -> meta model -> session model -> profile model ->
  routing-feedback history model -> router default model

  The `history_model` slot is populated by the router when the `routing_feedback`
  feature flag is enabled and sufficient historical performance data exists for the
  task context. It acts as a soft tie-breaker between the profile default and the
  router fallback — it never overrides explicit user intent.

  A supplied request model is explicit unless `model_explicit` is `false`.
  This lets automatic child defaults retain request precedence without treating
  a persona's model or routing role as an invocation-level override.
  An inherited explicit pin (`model_explicit: true`) also remains explicit when
  the concrete model comes from profile, history or router defaults. No selected
  model means no explicit selection.
  """

  @type t :: %{model: String.t() | nil, model_explicit: boolean()}

  @spec resolve(map()) :: t()
  def resolve(input) when is_map(input) do
    case normalize_string(input[:explicit_model]) do
      nil ->
        explicit =
          normalize_string(input[:meta_model]) ||
            normalize_string(input[:session_model])

        if explicit do
          %{model: explicit, model_explicit: true}
        else
          resolved_model =
            normalize_string(input[:profile_model]) ||
              normalize_string(input[:history_model]) ||
              normalize_string(input[:default_model])

          %{
            model: resolved_model,
            model_explicit: not is_nil(resolved_model) and input[:model_explicit] == true
          }
        end

      model ->
        %{model: model, model_explicit: input[:model_explicit] != false}
    end
  end

  def resolve(_), do: %{model: nil, model_explicit: false}

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil
end
