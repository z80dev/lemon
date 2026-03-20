defmodule LemonAiRuntime.Auth.OAuthSecretResolver do
  @moduledoc """
  Lemon-side façade for OAuth secret resolution during AI extraction.
  """

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  defdelegate resolve_api_key_from_secret(secret_name, secret_value),
    to: Ai.Auth.OAuthSecretResolver
end

