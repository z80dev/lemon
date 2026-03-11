defmodule Mix.Tasks.Lemon.Onboard.Copilot do
  use Mix.Task

  alias LemonCore.Onboarding.Providers
  alias LemonCore.Onboarding.Runner

  @shortdoc "Interactive onboarding for GitHub Copilot provider"
  @moduledoc """
  Interactive onboarding flow for GitHub Copilot.

  What it does:
  - Runs GitHub Copilot OAuth device flow by default, or accepts `--token`
  - Stores Copilot credentials in the encrypted Lemon secrets store
  - Writes `[providers.github_copilot].api_key_secret` to config.toml
  - Optionally sets `[defaults].provider` and `[defaults].model`

  Usage:
      mix lemon.onboard.copilot

      mix lemon.onboard.copilot --token <token>
      mix lemon.onboard.copilot --enterprise-domain company.ghe.com
      mix lemon.onboard.copilot --token <token> --set-default
      mix lemon.onboard.copilot --token <token> --set-default --model gpt-5
      mix lemon.onboard.copilot --token <token> --config-path /path/to/config.toml
  """

  @impl true
  def run(args) do
    Runner.run(args, Providers.fetch!("github_copilot"))
  end
end
