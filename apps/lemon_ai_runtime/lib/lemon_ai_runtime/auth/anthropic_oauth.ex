defmodule LemonAiRuntime.Auth.AnthropicOAuth do
  @moduledoc """
  Lemon-side facade for Anthropic OAuth resolution.
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
    to: Ai.Auth.AnthropicOAuth

  @spec resolve_access_token() :: String.t() | nil
  defdelegate resolve_access_token(), to: Ai.Auth.AnthropicOAuth
end
