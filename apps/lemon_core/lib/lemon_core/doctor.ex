defmodule LemonCore.Doctor do
  @moduledoc """
  Runs the Lemon doctor check suite and builds the aggregate diagnostic report used by CLI and support tooling.

  ## Registering checks

  The built-in checks cover what lemon_core itself owns (config, secrets,
  runtime, providers, and the proof artifacts other apps write). Apps that own
  their own domain register additional check modules, which run after the
  built-ins:

      config :lemon_core, :doctor_checks, [MyApp.Doctor.Checks.Widgets]

  A check module only has to export `run/1` returning a list of
  `LemonCore.Doctor.Check` structs. Modules that cannot be loaded are skipped,
  so a registration left behind by a removed dependency is not fatal.
  """
  alias LemonCore.Doctor.Checks.{
    ACP,
    Browser,
    Channels,
    Config,
    Cron,
    Extensions,
    LSP,
    Media,
    Memory,
    MCP,
    NodeTools,
    OpenAICompat,
    Providers,
    Runtime,
    Secrets,
    Skills,
    TerminalBackends,
    Usage
  }

  alias LemonCore.Doctor.Report

  @builtin_checks [
    Config,
    Secrets,
    Runtime,
    Providers,
    Usage,
    Channels,
    Media,
    Memory,
    Browser,
    Cron,
    TerminalBackends,
    OpenAICompat,
    ACP,
    MCP,
    LSP,
    Extensions,
    NodeTools,
    Skills
  ]

  @spec builtin_checks() :: [module()]
  def builtin_checks, do: @builtin_checks

  @doc """
  Check modules registered by other apps under `:lemon_core, :doctor_checks`.
  """
  @spec registered_checks() :: [module()]
  def registered_checks do
    :lemon_core
    |> Application.get_env(:doctor_checks, [])
    |> List.wrap()
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :run, 1)))
  end

  @spec checks(keyword()) :: [LemonCore.Doctor.Check.t()]
  def checks(opts \\ []) do
    (@builtin_checks ++ registered_checks())
    |> Enum.reduce([], fn module, acc -> append_checks(acc, module.run(opts)) end)
  end

  @spec report(keyword()) :: Report.t()
  def report(opts \\ []) do
    opts
    |> checks()
    |> Report.from_checks()
  end

  defp append_checks(acc, checks), do: acc ++ checks
end
