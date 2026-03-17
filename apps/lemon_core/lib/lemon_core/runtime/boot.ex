defmodule LemonCore.Runtime.Boot do
  @moduledoc """
  Orchestrates the Lemon runtime boot sequence.

  This module centralises the startup logic that previously lived in the
  `bin/lemon` shell script.  The script is kept as a thin CLI wrapper that
  sets environment variables and then calls into this module.

  ## Boot sequence

  1. Load `.env` from `dotenv_dir` (if present).
  2. Reject dev Erlang distribution cookie in production releases.
  3. Apply port values from the resolved `Env` struct to the OTP application
     environment.
  4. Start each application in the requested `Profile` in order.

  ## Usage (from a mix eval or release boot)

      LemonCore.Runtime.Boot.start(:runtime_full)

      # with explicit env override
      env = %LemonCore.Runtime.Env{control_port: 5050}
      LemonCore.Runtime.Boot.start(:runtime_min, env: env)
  """

  require Logger

  alias LemonCore.Runtime.{Env, Health, Profile}

  @doc """
  Starts a Lemon runtime using the given profile name.

  ## Options

    * `:env` - a `LemonCore.Runtime.Env` struct; defaults to `Env.resolve/0`.
    * `:dotenv_dir` - override the dotenv directory (default: `env.dotenv_dir`).
    * `:check_running` - when `true` (default), abort if a runtime is already
      running on the control-plane port.
  """
  @spec start(atom(), keyword()) :: :ok | {:error, {atom(), term()}}
  def start(profile_name \\ :runtime_full, opts \\ []) do
    env = Keyword.get(opts, :env, Env.resolve())
    dotenv_dir = Keyword.get(opts, :dotenv_dir, env.dotenv_dir)
    check_running? = Keyword.get(opts, :check_running, true)

    # 1. Load dotenv
    if dotenv_dir do
      LemonCore.Dotenv.load_and_log(dotenv_dir)
    end

    # 2. Reject missing/dev cookie in production contexts
    if production_context?() do
      Env.require_prod_cookie!()
    end

    # 3. Apply ports to OTP application env
    Env.apply_ports(env)

    # 4. Guard: already running?
    if check_running? and Health.running?(env.control_port) do
      Logger.warning(
        "[boot] Control plane already healthy on :#{env.control_port}. " <>
          "Another runtime may already be running — leaving existing runtime in place."
      )

      :ok
    else
      # 5. Start all apps in the profile
      profile = Profile.get(profile_name)
      Logger.info("[boot] Starting profile :#{profile_name} (#{length(profile.apps)} apps)")

      start_apps(profile.apps)
    end
  end

  @doc """
  Like `start/2` but halts the BEAM on failure.

  Used by `bin/lemon` where the process runs with `--no-halt` — without this,
  a boot failure would leave the BEAM sitting idle with no apps running and
  no error visible to the user.
  """
  @spec start!(atom(), keyword()) :: :ok
  def start!(profile_name \\ :runtime_full, opts \\ []) do
    case start(profile_name, opts) do
      :ok ->
        :ok

      {:error, {app, reason}} ->
        Logger.error(
          "[boot] Boot failed at :#{app}: #{inspect(reason)}\n" <>
            "[boot] Halting. Fix the error above and retry."
        )

        # Give the logger a moment to flush before exiting.
        Process.sleep(500)
        System.halt(1)
    end
  end

  @doc """
  Returns a summary of which apps in `profile_name` are currently started.
  """
  @spec status(atom()) :: map()
  def status(profile_name \\ :runtime_full) do
    profile = Profile.get(profile_name)
    Health.status(apps: profile.apps)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp start_apps(apps) do
    Enum.reduce_while(apps, :ok, fn app, :ok ->
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          Logger.info("[boot] Started :#{app}")
          {:cont, :ok}

        {:error, reason} ->
          Logger.error("[boot] Failed to start :#{app}: #{inspect(reason)}")
          {:halt, {:error, {app, reason}}}
      end
    end)
  end

  defp production_context? do
    is_binary(System.get_env("RELEASE_NODE")) or System.get_env("MIX_ENV") == "prod"
  end
end
