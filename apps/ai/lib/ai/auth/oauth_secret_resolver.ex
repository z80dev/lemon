defmodule Ai.Auth.OAuthSecretResolver do
  @moduledoc """
  Provider-agnostic OAuth secret resolver.

  Dispatches provider-specific OAuth secret payloads to the matching auth helper
  and returns a usable API key value.
  """

  @resolvers [
    Ai.Auth.GitHubCopilotOAuth,
    Ai.Auth.GoogleAntigravityOAuth,
    Ai.Auth.OpenAICodexOAuth
  ]

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value)
      when is_binary(secret_name) and is_binary(secret_value) do
    Enum.reduce_while(@resolvers, :ignore, fn resolver, _acc ->
      case resolver.resolve_api_key_from_secret(secret_name, secret_value) do
        :ignore ->
          {:cont, :ignore}

        {:ok, _api_key} = ok ->
          {:halt, ok}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  def resolve_api_key_from_secret(_, _), do: {:error, :invalid_secret_value}
end
