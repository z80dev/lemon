defmodule LemonCore.Runtime.Boot do
  @moduledoc """
  Orchestrates the Lemon runtime boot sequence.

  This module centralises the startup logic that previously lived in the
  `bin/lemon` shell script.  The script is kept as a thin CLI wrapper that
  sets environment variables and then calls into this module.

  ## Boot sequence

  1. Load `.env` from `dotenv_dir` (if present).
  2. Apply port values from the resolved `Env` struct to the OTP application
     environment.
  3. Check that the `product_runtime` feature flag permits boot (gated in M1).
  4. Start each application in the requested `Profile` in order.
  5. Log any failures and halt with exit code 1.

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
  @spec start(atom(), keyword()) :: :ok
  def start(profile_name \\ :runtime_full, opts \\ []) do
    env = Keyword.get(opts, :env, Env.resolve())
    dotenv_dir = Keyword.get(opts, :dotenv_dir, env.dotenv_dir)
    check_running? = Keyword.get(opts, :check_running, true)

    # 1. Load dotenv
    if dotenv_dir do
      LemonCore.Dotenv.load_and_log(dotenv_dir)
    end

    # 2. Apply ports to OTP application env
    Env.apply_ports(env)

    # 3. Guard: already running?
    if check_running? and Health.running?(env.control_port) do
      Logger.warning(
        "[boot] Control plane already healthy on :#{env.control_port}. " <>
          "Another runtime may already be running — leaving existing runtime in place."
      )

      :ok
    else
      # 4. Start all apps in the profile
      profile = Profile.get(profile_name)
      Logger.info("[boot] Starting profile :#{profile_name} (#{length(profile.apps)} apps)")
      start_apps(profile.apps)
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
    Enum.each(apps, fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          Logger.info("[boot] Started :#{app}")

        {:error, reason} ->
          Logger.error("[boot] Failed to start :#{app}: #{inspect(reason)}")
          System.halt(1)
      end
    end)
  end
end
