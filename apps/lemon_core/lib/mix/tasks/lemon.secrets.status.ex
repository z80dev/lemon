defmodule Mix.Tasks.Lemon.Secrets.Status do
  use Mix.Task

  alias LemonCore.Secrets

  @shortdoc "Show encrypted secrets status"
  @moduledoc """
  Shows master key status and secret count.

      mix lemon.secrets.status
  """

  @impl true
  def run(_args) do
    start_lemon_core!()

    status = Secrets.status()

    Mix.shell().info("configured: #{status.configured}")
    Mix.shell().info("source: #{status.source || "none"}")
    Mix.shell().info("keychain_available: #{status.keychain_available}")
    Mix.shell().info("env_fallback: #{status.env_fallback}")

    if status.keychain_error do
      Mix.shell().info("keychain_error: #{inspect(status.keychain_error)}")
    end

    Mix.shell().info("owner: #{status.owner}")
    Mix.shell().info("count: #{status.count}")
  end

  defp start_lemon_core! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
