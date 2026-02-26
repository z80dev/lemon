defmodule Mix.Tasks.Lemon.Onboard.Codex do
  use Mix.Task

  alias LemonCore.Onboarding.OAuthHelper

  @shortdoc "Interactive onboarding for OpenAI Codex provider"
  @moduledoc """
  Interactive onboarding flow for OpenAI Codex.

  What it does:
  - Runs OpenAI Codex OAuth flow by default
  - Stores credentials in the encrypted Lemon secrets store
  - Writes `[providers.openai-codex].api_key_secret` to config.toml
  - Optionally sets `[defaults].provider` and `[defaults].model`

  Usage:
      mix lemon.onboard.codex

      mix lemon.onboard.codex --token <token>
      mix lemon.onboard.codex --token <token> --set-default
      mix lemon.onboard.codex --token <token> --set-default --model gpt-5.2
      mix lemon.onboard.codex --token <token> --config-path /path/to/config.toml
  """

  @impl true
  def run(args) do
    OAuthHelper.run(args, %{
      display_name: "OpenAI Codex",
      provider_key: "openai-codex",
      provider_table: "providers.openai-codex",
      default_secret_name: "llm_openai_codex_api_key",
      default_secret_provider: "onboarding_openai_codex",
      oauth_secret_provider: "onboarding_openai_codex_oauth",
      oauth_module: Module.concat([Ai, Auth, OpenAICodexOAuth]),
      preferred_models: [
        "gpt-5.2",
        "gpt-5",
        "gpt-5-mini"
      ],
      oauth_failure_label: "OpenAI Codex OAuth login failed",
      token_resolution_hint:
        "OpenAI Codex OAuth flow did not return credentials. Retry and paste the callback URL/code, or pass --token."
    })
  end
end
