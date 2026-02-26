defmodule Mix.Tasks.Lemon.Onboard.Anthropic do
  use Mix.Task

  alias LemonCore.Onboarding.OAuthHelper

  @shortdoc "Interactive onboarding for Anthropic provider"
  @moduledoc """
  Interactive onboarding flow for Anthropic.

  What it does:
  - Runs Anthropic OAuth flow by default
  - Stores credentials in the encrypted Lemon secrets store
  - Writes `[providers.anthropic].api_key_secret` to config.toml
  - Optionally sets `[defaults].provider` and `[defaults].model`

  Usage:
      mix lemon.onboard.anthropic

      mix lemon.onboard.anthropic --token <token>
      mix lemon.onboard.anthropic --token <token> --set-default
      mix lemon.onboard.anthropic --token <token> --set-default --model claude-sonnet-4-20250514
      mix lemon.onboard.anthropic --token <token> --config-path /path/to/config.toml
  """

  @impl true
  def run(args) do
    OAuthHelper.run(args, %{
      display_name: "Anthropic",
      provider_key: "anthropic",
      provider_table: "providers.anthropic",
      default_secret_name: "llm_anthropic_api_key",
      default_secret_provider: "onboarding_anthropic",
      oauth_secret_provider: "onboarding_anthropic_oauth",
      oauth_module: Module.concat([Ai, Auth, AnthropicOAuth]),
      preferred_models: [
        "claude-sonnet-4-20250514",
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-6"
      ],
      oauth_failure_label: "Anthropic OAuth login failed"
    })
  end
end
