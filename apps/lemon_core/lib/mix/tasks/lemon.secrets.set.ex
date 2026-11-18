defmodule Mix.Tasks.Lemon.Secrets.Set do
  use Mix.Task

  alias LemonCore.Secrets

  @shortdoc "Store an encrypted secret"
  @moduledoc """
  Stores a secret value in the encrypted secrets store.

  Usage:
      mix lemon.secrets.set <name> <value>
      mix lemon.secrets.set --name <name> --value <value>
      mix lemon.secrets.set <name> <value> --provider manual --expires-at 1735689600000
  """

  @impl true
  def run(args) do
    Mix.Tasks.Lemon.Secrets.ensure_started!()

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [name: :string, value: :string, provider: :string, expires_at: :integer],
        aliases: [n: :name, v: :value]
      )

    {name, value} = parse_name_and_value(opts, positional)

    secrets_opts =
      []
      |> maybe_put(:provider, opts[:provider])
      |> maybe_put(:expires_at, opts[:expires_at])

    case Secrets.set(name, value, secrets_opts) do
      {:ok, metadata} ->
        Mix.shell().info("Stored secret #{metadata.name} (owner=#{metadata.owner})")

      {:error, :missing_master_key} ->
        Mix.raise(
          "Missing secrets master key. Run mix lemon.secrets.init or set LEMON_SECRETS_MASTER_KEY."
        )

      {:error, :weak_master_key} ->
        Mix.raise(
          "Secrets master key is not base64-encoded 32-byte key material. " <>
            "Run mix lemon.secrets.status for diagnostics; to keep secrets encrypted under it, " <>
            "allow legacy raw keys and run mix lemon.secrets.rotate_key."
        )

      {:error, {:keychain_failed, reason}} ->
        Mix.raise(
          "Failed to read secrets master key from keychain: #{inspect(reason)}. " <>
            "Nothing was written. Run mix lemon.secrets.status for diagnostics and restore " <>
            "keychain access; do not re-initialize the key."
        )

      {:error, :master_key_mismatch} ->
        Mix.raise(
          "The resolved secrets master key does not open the stored secrets, so nothing was " <>
            "written. Run mix lemon.secrets.status to see which key source is in use and " <>
            "restore the original key."
        )

      {:error, reason} ->
        Mix.raise("Failed to store secret: #{inspect(reason)}")
    end
  end

  defp parse_name_and_value(opts, positional) do
    case {opts[:name], opts[:value], positional} do
      {name, value, _} when is_binary(name) and is_binary(value) and name != "" and value != "" ->
        {name, value}

      {nil, nil, [name, value | _]} ->
        {name, value}

      _ ->
        Mix.raise("Usage: mix lemon.secrets.set <name> <value>")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
