defmodule Mix.Tasks.Lemon.Secrets.Init do
  use Mix.Task

  alias LemonCore.Secrets.MasterKey

  @shortdoc "Initialize Lemon secrets master key in keychain"
  @moduledoc """
  Initializes the encrypted secrets master key.

  This command stores a generated key in macOS Keychain.

      mix lemon.secrets.init
  """

  @impl true
  def run(_args) do
    start_lemon_core!()

    case MasterKey.init() do
      {:ok, _result} ->
        Mix.shell().info("Secrets master key initialized in keychain")

      {:error, :keychain_unavailable} ->
        Mix.raise("Keychain is unavailable on this system. Set #{MasterKey.env_var()} instead.")

      {:error, reason} ->
        Mix.raise("Failed to initialize secrets master key: #{inspect(reason)}")
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
