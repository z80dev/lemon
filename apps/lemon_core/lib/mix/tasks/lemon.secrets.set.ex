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
    start_lemon_core!()

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

      {:error, {:keychain_failed, reason}} ->
        Mix.raise(
          "Failed to read secrets master key from keychain: #{inspect(reason)}. " <>
            "Run mix lemon.secrets.status for diagnostics, then re-run mix lemon.secrets.init " <>
            "or set LEMON_SECRETS_MASTER_KEY."
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

  defp start_lemon_core! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
