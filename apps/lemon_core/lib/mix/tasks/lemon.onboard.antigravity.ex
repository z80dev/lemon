defmodule Mix.Tasks.Lemon.Onboard.Antigravity do
  use Mix.Task

  alias LemonCore.Onboarding.OAuthHelper

  @shortdoc "Interactive onboarding for Google Antigravity provider"
  @moduledoc """
  Interactive onboarding flow for Google Antigravity.

  What it does:
  - Runs Google Antigravity OAuth flow by default
  - Stores credentials in the encrypted Lemon secrets store
  - Writes `[providers.google_antigravity].api_key_secret` to config.toml
  - Optionally sets `[defaults].provider` and `[defaults].model`

  Usage:
      mix lemon.onboard.antigravity

      mix lemon.onboard.antigravity --token <token>
      mix lemon.onboard.antigravity --token <token> --set-default
      mix lemon.onboard.antigravity --token <token> --set-default --model gemini-3-pro-high
      mix lemon.onboard.antigravity --token <token> --config-path /path/to/config.toml
  """

  @impl true
  def run(args) do
    OAuthHelper.run(args, %{
      display_name: "Google Antigravity",
      provider_key: "google_antigravity",
      provider_table: "providers.google_antigravity",
      default_secret_name: "llm_google_antigravity_api_key",
      default_secret_provider: "onboarding_google_antigravity",
      oauth_secret_provider: "onboarding_google_antigravity_oauth",
      oauth_module: Module.concat([Ai, Auth, GoogleAntigravityOAuth]),
      preferred_models: [
        "gemini-3-pro-high",
        "gemini-3-pro-low",
        "gemini-3-flash"
      ],
      oauth_failure_label: "Google Antigravity OAuth login failed"
    })
  end
end
