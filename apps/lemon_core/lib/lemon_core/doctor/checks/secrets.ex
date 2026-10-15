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
          "Run `lemon secrets init` to provision the key (system keychain on macOS,\n" <>
            "a private key file elsewhere), or set #{MasterKey.env_var()} in your environment."
        )

      {:error, :weak_master_key} ->
        Check.fail(
          "secrets.master_key",
          "Master key is not base64-encoded 32-byte key material.",
          "Run `lemon secrets status` before changing an existing key; replacing it can make stored secrets unreadable.\n" <>
            "Generate new key material with `lemon secrets init` or `openssl rand -base64 32`."
        )

      {:error, _reason} ->
        Check.warn(
          "secrets.master_key",
          "The encrypted secrets master key could not be verified.",
          "Run `lemon secrets status` for guidance."
        )
    end
  end
end
