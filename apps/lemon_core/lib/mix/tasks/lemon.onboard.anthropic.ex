defmodule Mix.Tasks.Lemon.Onboard.Anthropic do
  use Mix.Task

  alias LemonCore.Onboarding.Providers
  alias LemonCore.Onboarding.Runner

  @shortdoc "Interactive onboarding for Anthropic provider"
  @moduledoc """
  Interactive onboarding flow for Anthropic.

  What it does:
  - Prompts for an Anthropic API key
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
    Runner.run(args, Providers.fetch!("anthropic"))
  end
end
