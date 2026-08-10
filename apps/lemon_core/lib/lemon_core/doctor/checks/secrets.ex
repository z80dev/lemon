defmodule LemonCore.Doctor.Checks.Secrets do
  @moduledoc "Checks encrypted secrets readiness."

  alias LemonCore.Doctor.Check
  alias LemonCore.Secrets.MasterKey

  @doc """
  Returns a list of Check results covering secrets configuration.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(_opts \\ []) do
    [
      check_master_key_configured()
    ]
  end

  defp check_master_key_configured do
    case MasterKey.resolve() do
      {:ok, _key, source} ->
        Check.pass("secrets.master_key", "Master key available (source: #{source}).")

      {:error, :missing_master_key} ->
        Check.fail(
          "secrets.master_key",
          "Encrypted secrets master key is not configured.",
          "Run `mix lemon.secrets.init` to provision the key (system keychain on macOS,\n" <>
            "#{MasterKey.key_file() || "the configured key file"} elsewhere),\n" <>
            "or set #{MasterKey.env_var()} in your environment."
        )

      {:error, :weak_master_key} ->
        Check.fail(
          "secrets.master_key",
          "Master key is not base64-encoded 32-byte key material.",
          "Generate one with `mix lemon.secrets.init` or `openssl rand -base64 32`.\n" <>
            "To keep an existing raw-string key, set\n" <>
            "`config :lemon_core, LemonCore.Secrets, allow_legacy_raw_keys: true`."
        )

      {:error, reason} ->
        Check.warn(
          "secrets.master_key",
          "Could not verify master key: #{inspect(reason)}.",
          "Run `mix lemon.secrets.status` for details."
        )
    end
  end
end
