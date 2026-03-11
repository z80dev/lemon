defmodule Ai.Providers.MistralConversations do
  @moduledoc """
  Mistral Conversations API provider.

  Wraps the OpenAI Completions provider since Mistral's API is OpenAI-compatible,
  but the native Mistral SDK uses the base URL without /v1.
  This provider adjusts the URL before delegating to the OpenAI completions implementation.
  """

  @behaviour Ai.Provider

  alias Ai.Types.{Model, StreamOptions, Context}

  @impl true
  def api_id, do: :mistral_conversations

  @impl true
  def provider_id, do: :mistral

  @impl true
  def get_env_api_key do
    LemonCore.Secrets.fetch_value("MISTRAL_API_KEY")
  end

  @impl true
  def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = options) do
    # Adjust base_url to append /v1 for OpenAI-compatible endpoint
    adjusted_model = %{model | base_url: "#{model.base_url}/v1"}
    Ai.Providers.OpenAICompletions.stream(adjusted_model, context, options)
  end
end
