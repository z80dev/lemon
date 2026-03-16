defmodule Mix.Tasks.Lemon.Setup do
  use Mix.Task

  alias LemonCore.Onboarding.Runner
  alias LemonCore.Setup.{Gateway, Provider, Wizard}

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
    # parse_head stops at the first non-flag argument (the subcommand name),
    # leaving subcommand-specific flags untouched so subcommand parsers get them.
    {opts, rest, _invalid} =
      OptionParser.parse_head(args,
        switches: [non_interactive: :boolean, config_path: :string],
        aliases: [n: :non_interactive]
      )

    case rest do
      ["provider" | provider_args] ->
        ensure_apps_started!()
        Provider.run(provider_args, io)

      ["runtime" | runtime_args] ->
        Wizard.run_runtime(runtime_args, io, opts)

      ["gateway" | gateway_args] ->
        Gateway.run(gateway_args, io)

      ["doctor" | _doctor_args] ->
        run_doctor(io)

      [] ->
        ensure_apps_started!()
        Wizard.run_full([], io, opts)

      [subcommand | _] ->
        io.error.("Unknown subcommand: #{inspect(subcommand)}")
        io.info.("")
        io.info.("Usage: mix lemon.setup [provider|runtime|gateway|doctor] [options]")
        io.info.("Run `mix help lemon.setup` for full documentation.")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp ensure_apps_started! do
    Mix.Task.run("loadpaths")

    [:lemon_core, :ai]
    |> Enum.each(fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _} -> :ok
        {:error, reason} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
      end
    end)
  end

  defp run_doctor(_io) do
    Mix.Task.run("lemon.doctor", [])
  end
end
