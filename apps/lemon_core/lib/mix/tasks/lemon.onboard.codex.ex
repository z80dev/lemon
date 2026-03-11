defmodule Mix.Tasks.Lemon.Onboard.Codex do
  use Mix.Task

  alias LemonCore.Onboarding.Providers
  alias LemonCore.Onboarding.Runner

  @shortdoc "Interactive onboarding for OpenAI Codex provider"
  @moduledoc """
  Interactive onboarding flow for OpenAI Codex.

  What it does:
  - Runs OpenAI Codex OAuth flow by default, or accepts `--token`
  - Stores credentials in the encrypted Lemon secrets store
  - Writes `[providers.openai-codex].auth_source` plus either `oauth_secret` or `api_key_secret`
  - Optionally sets `[defaults].provider` and `[defaults].model`

  Usage:
      mix lemon.onboard.codex

      mix lemon.onboard.codex --token <token>
      mix lemon.onboard.codex --auth api_key
      mix lemon.onboard.codex --token <token> --set-default
      mix lemon.onboard.codex --token <token> --set-default --model gpt-5.2
      mix lemon.onboard.codex --token <token> --config-path /path/to/config.toml
  """

  @impl true
  def run(args) do
    Runner.run(args, Providers.fetch!("openai-codex"))
  end
end
