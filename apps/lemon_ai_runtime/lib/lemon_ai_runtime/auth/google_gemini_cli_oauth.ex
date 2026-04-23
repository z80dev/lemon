defmodule LemonAiRuntime.Auth.GoogleGeminiCliOAuth do
  @moduledoc """
  Lemon-side façade for Google Gemini CLI OAuth secret resolution.
  """

  alias LemonCore.Onboarding.LocalCallbackListener
  alias LemonCore.Secrets

  @provider "google_gemini_cli_oauth"

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value) do
    Ai.Auth.GoogleGeminiCliOAuth.resolve_api_key_from_secret(secret_name, secret_value,
      persist_secret: &persist_secret/2
    )
  end

  def login_device_flow(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.put_new(:local_callback_listener, LocalCallbackListener)
    |> Ai.Auth.GoogleGeminiCliOAuth.login_device_flow()
  end

  defdelegate authorize_url(opts \\ []), to: Ai.Auth.GoogleGeminiCliOAuth
  defdelegate build_authorize_url(opts \\ []), to: Ai.Auth.GoogleGeminiCliOAuth

  defdelegate exchange_code_for_secret(code, code_verifier, opts \\ []),
    to: Ai.Auth.GoogleGeminiCliOAuth

  defdelegate parse_authorization_input(input), to: Ai.Auth.GoogleGeminiCliOAuth
  defdelegate encode_secret(secret), to: Ai.Auth.GoogleGeminiCliOAuth
  defdelegate decode_secret(secret_value), to: Ai.Auth.GoogleGeminiCliOAuth

  defp persist_secret(secret_name, encoded_secret) do
    Secrets.set(secret_name, encoded_secret, provider: @provider)
    :ok
  end
end
