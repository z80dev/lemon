defmodule Mix.Tasks.Lemon.Secrets.Init do
  use Mix.Task

  alias LemonCore.Secrets.MasterKey

  @shortdoc "Initialize Lemon secrets master key"
  @moduledoc """
  Initializes the encrypted secrets master key.

  Stores a generated key in the first available backend for this platform:

      macOS:   Keychain → file (~/.lemon/master.key)
      Linux:   Secret Service → file (~/.lemon/master.key)
      Other:   file (~/.lemon/master.key)

  If no backend succeeds, set `#{MasterKey.env_var()}` manually.

      mix lemon.secrets.init
  """

  @source_labels %{
    keychain: "macOS Keychain",
    secret_service: "Secret Service (libsecret)",
    key_file: "file (~/.lemon/master.key)"
  }

  @impl true
  def run(_args) do
    start_lemon_core!()

    case MasterKey.init() do
      {:ok, %{source: source}} ->
        label = Map.get(@source_labels, source, to_string(source))
        Mix.shell().info("Secrets master key initialized in #{label}")

      {:error, :no_backend_available} ->
        Mix.raise(
          "No key storage backend available. Set #{MasterKey.env_var()} instead."
        )

      {:error, :keychain_unavailable} ->
        Mix.raise(
          "Keychain is unavailable on this system. Set #{MasterKey.env_var()} instead."
        )

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
