defmodule Mix.Tasks.Lemon.Secrets.Delete do
  use Mix.Task

  alias LemonCore.Secrets

  @shortdoc "Delete a stored secret"
  @moduledoc """
  Deletes a secret by name.

  Usage:
      mix lemon.secrets.delete <name>
      mix lemon.secrets.delete --name <name>
  """

  @impl true
  def run(args) do
    start_lemon_core!()

    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [name: :string], aliases: [n: :name])

    name = opts[:name] || List.first(positional)

    if not is_binary(name) or String.trim(name) == "" do
      Mix.raise("Usage: mix lemon.secrets.delete <name>")
    end

    case Secrets.delete(name) do
      :ok -> Mix.shell().info("Deleted secret #{String.trim(name)}")
      {:error, reason} -> Mix.raise("Failed to delete secret: #{inspect(reason)}")
    end
  end

  defp start_lemon_core! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
