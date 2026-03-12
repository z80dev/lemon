defmodule Mix.Tasks.Lemon.Onboard.Gemini do
  use Mix.Task

  alias LemonCore.Onboarding.Providers
  alias LemonCore.Onboarding.Runner

  @shortdoc "Interactive onboarding for Google Gemini CLI provider"
  @moduledoc """
  Interactive onboarding flow for Google Gemini CLI / Code Assist.

  What it does:
  - Runs Google Gemini OAuth by default, or accepts a credential payload via `--token`
  - Stores credentials in the encrypted Lemon secrets store
  - Writes `[providers.google_gemini_cli].api_key_secret` to config.toml
  - Optionally sets `[defaults].provider` and `[defaults].model`

  Usage:
      mix lemon.onboard.gemini

      mix lemon.onboard.gemini --project-id your-gcp-project
      mix lemon.onboard.gemini --token <token>
      mix lemon.onboard.gemini --token <token> --set-default --model gemini-2.5-pro
      mix lemon.onboard.gemini --token <token> --config-path /path/to/config.toml
  """

  @impl true
  def run(args) do
    Runner.run(args, Providers.fetch!("google_gemini_cli"))
  end
end
