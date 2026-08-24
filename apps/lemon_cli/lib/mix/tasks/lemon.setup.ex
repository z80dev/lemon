defmodule Mix.Tasks.Lemon.Setup do
  use Mix.Task

  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.Wizard

  @shortdoc "First-time setup and configuration"

  @moduledoc """
  Interactive first-time setup for Lemon.

  Without a subcommand, runs the full setup wizard covering secrets,
  provider onboarding, and runtime configuration.

  ## Subcommands

      mix lemon.setup             — full interactive wizard
      mix lemon.setup provider    — configure an AI provider (wraps lemon.onboard)
      mix lemon.setup runtime     — configure runtime profile and port bindings
      mix lemon.setup gateway     — configure gateway adapters
      mix lemon.setup doctor      — validate config and report health

  ## Options

      --non-interactive, -n       — skip prompts, use defaults / CLI flags
      --config-path PATH          — config file to read/write (full wizard only)

  ## Provider subcommand

      mix lemon.setup provider
      mix lemon.setup provider anthropic
      mix lemon.setup provider --provider copilot

  All flags accepted by `mix lemon.onboard` work here.

  ## Runtime subcommand

      mix lemon.setup runtime
      mix lemon.setup runtime --profile runtime_min
      mix lemon.setup runtime --control-port 5050 --web-port 5080

  ## Doctor subcommand

  Validates the current configuration and checks application health.
  Full diagnostics framework is delivered in M1-04 (`mix lemon.doctor`).
  """

  @impl true
  def run(args) do
    run_with_io(args, Runner.default_io())
  end

  @doc false
  def run_with_io(args, io) when is_list(args) and is_map(io) do
    # Thin source-checkout adapter: the runtime dispatch lives in
    # LemonCli.Setup.Wizard so packaged releases run the same code without Mix.
    Mix.Task.run("loadpaths", [])
    Wizard.run(args, io)
  end
end
