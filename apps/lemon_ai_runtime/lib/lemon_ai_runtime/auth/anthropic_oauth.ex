defmodule LemonAiRuntime.Auth.AnthropicOAuth do
  @moduledoc """
  Lemon-side facade for Anthropic OAuth resolution.
  """

  alias LemonCore.Secrets

  @default_secret_names ["llm_anthropic_api_key"]
  @provider "anthropic_oauth"

  @spec available?() :: boolean()
  def available? do
    case resolve_access_token() do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  rescue
    _ -> false
  end

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value) do
    Ai.Auth.AnthropicOAuth.resolve_api_key_from_secret(secret_name, secret_value,
      persist_secret: &persist_secret/2
    )
  end

  @spec resolve_access_token() :: String.t() | nil
  def resolve_access_token do
    Ai.Auth.AnthropicOAuth.resolve_access_token() ||
      Enum.find_value(@default_secret_names, fn secret_name ->
        with {:ok, value, _source} <-
               Secrets.resolve(secret_name,
                 prefer_env: false,
                 env_fallback: false
               ),
             {:ok, access_token} <- resolve_api_key_from_secret(secret_name, value) do
          access_token
        else
          _ -> nil
        end
      end)
  end

  defdelegate login_device_flow(opts \\ []), to: Ai.Auth.AnthropicOAuth
  defdelegate encode_secret(secret), to: Ai.Auth.AnthropicOAuth
  defdelegate decode_secret(secret_value), to: Ai.Auth.AnthropicOAuth
  defdelegate oauth_token?(token), to: Ai.Auth.AnthropicOAuth
  defdelegate oauth_beta_features(), to: Ai.Auth.AnthropicOAuth
  defdelegate oauth_headers(), to: Ai.Auth.AnthropicOAuth

  defp persist_secret(secret_name, encoded_secret) do
    Secrets.set(secret_name, encoded_secret, provider: @provider)
    :ok
  end
end
