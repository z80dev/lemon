defmodule LemonAiRuntime.Auth.OpenAICodexOAuth do
  @moduledoc """
  Lemon-side façade for OpenAI Codex OAuth resolution.
  """

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
  defdelegate resolve_api_key_from_secret(secret_name, secret_value),
    to: Ai.Auth.OpenAICodexOAuth

  @spec resolve_access_token() :: String.t() | nil
  defdelegate resolve_access_token(), to: Ai.Auth.OpenAICodexOAuth
end
