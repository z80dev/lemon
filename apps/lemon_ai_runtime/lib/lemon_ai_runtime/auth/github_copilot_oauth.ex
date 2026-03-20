defmodule LemonAiRuntime.Auth.GitHubCopilotOAuth do
  @moduledoc """
  Lemon-side façade for GitHub Copilot OAuth secret resolution.
  """

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  defdelegate resolve_api_key_from_secret(secret_name, secret_value),
    to: Ai.Auth.GitHubCopilotOAuth
end

