defmodule LemonAiRuntime.Auth.OpenAICodexOAuth do
  @moduledoc """
  Lemon-side façade for OpenAI Codex OAuth resolution.
  """

  alias LemonCore.Onboarding.LocalCallbackListener
  alias LemonCore.Secrets

  @default_secret_names ["llm_openai_codex_api_key"]
  @provider "openai_codex_oauth"

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
    Ai.Auth.OpenAICodexOAuth.resolve_api_key_from_secret(secret_name, secret_value,
      persist_secret: &persist_secret/2
    )
  end

  @spec resolve_access_token() :: String.t() | nil
  def resolve_access_token do
    resolve_named_secret("OPENAI_CODEX_API_KEY", prefer_env: true, env_fallback: true) ||
      resolve_named_secret("CHATGPT_TOKEN", prefer_env: true, env_fallback: true) ||
      Enum.find_value(@default_secret_names, fn secret_name ->
        resolve_named_secret(secret_name, prefer_env: false, env_fallback: false)
      end) ||
      Ai.Auth.OpenAICodexOAuth.resolve_access_token()
  end

  def login_device_flow(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.put_new(:local_callback_listener, LocalCallbackListener)
    |> Ai.Auth.OpenAICodexOAuth.login_device_flow()
  end

  defdelegate authorize_url(opts \\ []), to: Ai.Auth.OpenAICodexOAuth
  defdelegate build_authorize_url(opts \\ []), to: Ai.Auth.OpenAICodexOAuth

  defdelegate exchange_code_for_secret(code, code_verifier, opts \\ []),
    to: Ai.Auth.OpenAICodexOAuth

  defdelegate parse_authorization_input(input), to: Ai.Auth.OpenAICodexOAuth
  defdelegate encode_secret(secret), to: Ai.Auth.OpenAICodexOAuth
  defdelegate decode_secret(secret_value), to: Ai.Auth.OpenAICodexOAuth

  defp resolve_named_secret(secret_name, opts) when is_binary(secret_name) do
    with {:ok, value, _source} <- Secrets.resolve(secret_name, opts) do
      case resolve_api_key_from_secret(secret_name, value) do
        {:ok, api_key} -> api_key
        :ignore -> non_empty_binary(value)
        {:error, _reason} -> non_empty_binary(value)
      end
    else
      _ -> nil
    end
  end

  defp persist_secret(secret_name, encoded_secret) do
    Secrets.set(secret_name, encoded_secret, provider: @provider)
    :ok
  end

  defp non_empty_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_binary(_), do: nil
end
