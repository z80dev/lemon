defmodule LemonRouter.ModelSelection do
  @moduledoc """
  Resolves model selection independently from execution routing.

  This is the one place model and thinking-level precedence is decided; the
  router's admission and the control plane's session projection both call it.

  Model precedence (highest to lowest):

  request model -> meta model -> session model (`LemonCore.PolicyStore`
  session row) -> chat model (the most specific `PolicyStore` chat row of the
  session's channel route) -> profile model -> routing-feedback history model
  -> router default model

  Thinking-level precedence: request -> session row -> chat row.

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
            normalize_string(input[:session_model]) ||
            normalize_string(input[:chat_model])

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

  @doc "The thinking level a run uses: request, then session row, then chat row."
  @spec thinking_level(map()) :: term()
  def thinking_level(input) when is_map(input) do
    Enum.find_value([:request_thinking_level, :session_thinking_level, :chat_thinking_level], fn
      key -> present(input[key])
    end)
  end

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(value), do: value

  @doc """
  Whether `resolve/1` selects its model from operator configuration: the
  agent profile model or the router default (no request, meta, session, chat
  or routing-feedback model). Sessions resolve such a selector, `@role`
  included, against the operator's settings only.
  """
  @spec operator_source?(map()) :: boolean()
  def operator_source?(input) when is_map(input) do
    selected? = fn key -> not is_nil(normalize_string(input[key])) end

    not selected?.(:explicit_model) and not selected?.(:meta_model) and
      not selected?.(:session_model) and not selected?.(:chat_model) and
      (selected?.(:profile_model) or
         (not selected?.(:history_model) and selected?.(:default_model)))
  end

  def operator_source?(_), do: false

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil
end
