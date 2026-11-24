defmodule Mix.Tasks.Lemon.Secrets do
  @moduledoc false

  def ensure_started! do
    Mix.Task.run("loadpaths")

    case LemonCore.CLI.start(:lemon_core) do
      :ok -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
