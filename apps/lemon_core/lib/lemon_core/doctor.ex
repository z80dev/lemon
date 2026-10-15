defmodule LemonCore.Doctor do
  @moduledoc """
  Runs the Lemon doctor check suite and builds the aggregate diagnostic report used by CLI and support tooling.

  ## Registering checks

  The built-in checks cover what lemon_core itself owns (config, secrets,
  runtime, providers, usage, and node tools). Apps that own their own domain
  — memory, skills, channels, automation — register additional check modules,
  which run after the built-ins:

      config :lemon_core, :doctor_checks, [MyApp.Doctor.Checks.Widgets]

  A check module only has to export `run/1` returning a list of
  `LemonCore.Doctor.Check` structs. Modules that cannot be loaded are skipped,
  so a registration left behind by a removed dependency is not fatal.

  Modules may also export `live_checks/1`, returning `{name, zero_arity_fun}`
  jobs. These run only with `live: true`, concurrently under a shared deadline.
  Jobs must return a Check and must never generate completions or send messages.
  """
  alias LemonCore.Doctor.Checks.{
    Config,
    NodeTools,
    Providers,
    Runtime,
    Secrets,
    Usage
  }

  alias LemonCore.Doctor.{Check, LiveChecks, Report}

  @builtin_checks [
    Config,
    Secrets,
    Runtime,
    Providers,
    Usage,
    NodeTools
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

  @spec checks(keyword()) :: [Check.t()]
  def checks(opts \\ []) do
    modules = @builtin_checks ++ registered_checks()

    offline =
      Enum.reduce(modules, [], fn module, acc -> append_checks(acc, run_checks(module, opts)) end)

    if Keyword.get(opts, :live, false) do
      jobs =
        Enum.flat_map(modules, fn module ->
          if function_exported?(module, :live_checks, 1), do: module.live_checks(opts), else: []
        end)

      offline ++ LiveChecks.run(jobs, opts)
    else
      offline
    end
  end

  @spec report(keyword()) :: Report.t()
  def report(opts \\ []) do
    opts
    |> checks()
    |> Report.from_checks()
  end

  defp run_checks(module, opts) do
    module.run(opts)
  rescue
    _error ->
      [
        Check.fail(
          "doctor.check_failed",
          "A diagnostic check could not complete.",
          "Run `lemon config validate --verbose`; for removed settings run `lemon config migrate`."
        )
      ]
  catch
    _, _ ->
      [
        Check.fail(
          "doctor.check_failed",
          "A diagnostic check stopped unexpectedly.",
          "Run `lemon doctor --verbose` after checking the configuration."
        )
      ]
  end

  defp append_checks(acc, checks), do: acc ++ checks
end
