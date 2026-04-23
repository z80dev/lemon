defmodule LemonAiRuntime.Auth.OAuthSecretResolver do
  @moduledoc """
  Lemon-side façade for OAuth secret resolution during AI extraction.
  """

  @resolvers [
    LemonAiRuntime.Auth.AnthropicOAuth,
    LemonAiRuntime.Auth.GitHubCopilotOAuth,
    LemonAiRuntime.Auth.GoogleAntigravityOAuth,
    LemonAiRuntime.Auth.GoogleGeminiCliOAuth,
    LemonAiRuntime.Auth.OpenAICodexOAuth
  ]

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value)
      when is_binary(secret_name) and is_binary(secret_value) do
    Enum.reduce_while(@resolvers, :ignore, fn resolver, _acc ->
      case resolver.resolve_api_key_from_secret(secret_name, secret_value) do
        :ignore -> {:cont, :ignore}
        {:ok, _api_key} = ok -> {:halt, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def resolve_api_key_from_secret(_, _), do: {:error, :invalid_secret_value}
end
