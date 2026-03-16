defmodule LemonCore.Setup.Provider do
  @moduledoc """
  Provider setup helpers for `mix lemon.setup provider`.

  Wraps `Mix.Tasks.Lemon.Onboard` with setup-context-aware pre-checks so
  the setup command can give a better first-time experience: secrets init
  guard and a config scaffold before the onboarding proper.
  """

  alias LemonCore.Secrets
  alias LemonCore.Setup.Scaffold

  @doc """
  Runs provider onboarding within the setup context.

  Pre-checks:
  1. Secrets must be initialized — if not, prints guidance and exits.
  2. Bootstraps the global config scaffold when none exists yet.

  Delegates to `Mix.Tasks.Lemon.Onboard.run_with_io/2` for the actual
  onboarding flow (provider picker, OAuth/API-key, etc.).
  """
  @spec run([String.t()], map()) :: :ok
  def run(args, io) when is_list(args) and is_map(io) do
    with :ok <- ensure_secrets_ready(io),
         :ok <- maybe_bootstrap_config(io) do
      Mix.Tasks.Lemon.Onboard.run_with_io(args, io)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp ensure_secrets_ready(io) do
    status = Secrets.status()

    if status.configured do
      :ok
    else
      io.error.("Encrypted secrets are not configured.")
      io.info.("")
      io.info.("Run this first, then retry:")
      io.info.("  mix lemon.secrets.init")
      io.info.("")
      {:error, :secrets_not_configured}
    end
  end

  defp maybe_bootstrap_config(io) do
    if Scaffold.global_config_exists?() do
      :ok
    else
      result =
        try do
          Scaffold.bootstrap_global()
        rescue
          e -> {:error, Exception.message(e)}
        end

      case result do
        {:ok, path} ->
          io.info.("Created minimal config: #{path}")
          io.info.("Edit it to add your preferred defaults, then re-run this command.")
          io.info.("")
          :ok

        {:exists, _path} ->
          :ok

        {:error, reason} ->
          io.error.("Failed to create config scaffold: #{inspect(reason)}")
          {:error, {:scaffold_failed, reason}}
      end
    end
  end
end
