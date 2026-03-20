defmodule LemonAiRuntime.Auth.GoogleAntigravityOAuth do
  @moduledoc """
  Lemon-side façade for Google Antigravity OAuth secret resolution.
  """

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  defdelegate resolve_api_key_from_secret(secret_name, secret_value),
    to: Ai.Auth.GoogleAntigravityOAuth
end

