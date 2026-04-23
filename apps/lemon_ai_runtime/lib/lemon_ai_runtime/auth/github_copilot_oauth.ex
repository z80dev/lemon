defmodule LemonAiRuntime.Auth.GitHubCopilotOAuth do
  @moduledoc """
  Lemon-side façade for GitHub Copilot OAuth secret resolution.
  """

  alias LemonCore.Secrets

  @provider "github_copilot_oauth"

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value) do
    Ai.Auth.GitHubCopilotOAuth.resolve_api_key_from_secret(secret_name, secret_value,
      persist_secret: &persist_secret/2
    )
  end

  defdelegate login_device_flow(opts \\ []), to: Ai.Auth.GitHubCopilotOAuth
  defdelegate encode_secret(secret), to: Ai.Auth.GitHubCopilotOAuth
  defdelegate normalize_domain(input), to: Ai.Auth.GitHubCopilotOAuth

  defp persist_secret(secret_name, encoded_secret) do
    Secrets.set(secret_name, encoded_secret, provider: @provider)
    :ok
  end
end
