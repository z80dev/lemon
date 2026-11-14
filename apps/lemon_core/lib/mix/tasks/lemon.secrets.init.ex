defmodule Mix.Tasks.Lemon.Secrets.Init do
  use Mix.Task

  alias LemonCore.Secrets.MasterKey

  @shortdoc "Initialize Lemon secrets master key"
  @moduledoc """
  Initializes the encrypted secrets master key.

  This command stores a generated key with the first writable key provider:
  the macOS Keychain where it is available, otherwise the key file
  (`~/.lemon/secrets_master_key` by default, `0600`).

      mix lemon.secrets.init

  Options:

    * `--target file` — force a specific provider (`keychain` or `file`)
    * `--force` — overwrite an existing key file. Every secret encrypted under
      the previous key becomes unreadable; to change a key in use and keep its
      secrets, run `mix lemon.secrets.rotate_key` instead.
  """

  @impl true
  def run(args) do
    Mix.Tasks.Lemon.Secrets.ensure_started!()

    {parsed, _rest, _invalid} =
      OptionParser.parse(args, strict: [target: :string, force: :boolean])

    case MasterKey.init(init_opts(parsed)) do
      {:ok, %{source: :file, key_file: path}} ->
        Mix.shell().info("Secrets master key written to #{path} (0600)")

      {:ok, %{source: source}} ->
        Mix.shell().info("Secrets master key initialized in #{source}")

      {:error, :keychain_unavailable} ->
        Mix.raise(
          "Keychain is unavailable on this system and no key file location could be " <>
            "determined. Set #{MasterKey.env_var()}, or configure " <>
            "`config :lemon_core, LemonCore.Secrets, key_file: ...`."
        )

      {:error, {:key_file_exists, path}} ->
        Mix.raise(
          "A secrets master key already exists at #{path}. Re-run with --force to " <>
            "replace it — every secret encrypted under the old key becomes unreadable. " <>
            "To change the key and keep secrets, run `mix lemon.secrets.rotate_key`."
        )

      {:error, reason} ->
        Mix.raise("Failed to initialize secrets master key: #{inspect(reason)}")
    end
  end

  defp init_opts(parsed) do
    opts = if parsed[:force], do: [force: true], else: []

    case parsed[:target] do
      nil -> opts
      target -> [{:target, String.to_atom(target)} | opts]
    end
  end
end
