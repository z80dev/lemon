defmodule Mix.Tasks.Lemon.Onboard.Antigravity do
  use Mix.Task

  alias LemonCore.Onboarding.Providers
  alias LemonCore.Onboarding.Runner

  @shortdoc "Interactive onboarding for Google Antigravity provider"
  @moduledoc """
  Interactive onboarding flow for Google Antigravity.

  What it does:
  - Runs Google Antigravity OAuth flow by default, or accepts a credential payload via `--token`
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
    Runner.run(args, Providers.fetch!("google_antigravity"))
  end
end
