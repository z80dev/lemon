defmodule Mix.Tasks.Lemon.Secrets.Check do
  use Mix.Task

  alias LemonCore.Secrets
  alias LemonCore.Secrets.EnvCatalog

  @shortdoc "Check secret resolution sources"
  @moduledoc """
  Reports the resolution source for each known secret — whether it resolves
  from the encrypted store, from an env var, or is missing entirely.

  Usage:
      mix lemon.secrets.check
  """

  def known_secrets, do: EnvCatalog.names()

  @impl true
  def run(_args) do
    start_lemon_core!()

    # Find the longest name for column alignment
    max_name_len =
      EnvCatalog.names()
      |> Enum.map(&String.length/1)
      |> Enum.max()

    # Header
    Mix.shell().info(String.pad_trailing("NAME", max_name_len) <> "  SOURCE   VALUE")

    Mix.shell().info(String.duplicate("-", max_name_len + 30))

    results = Enum.map(EnvCatalog.names(), &check_secret(&1, max_name_len))

    from_store = Enum.count(results, &(&1 == :store))
    from_env = Enum.count(results, &(&1 == :env))
    missing = Enum.count(results, &(&1 == :missing))

    Mix.shell().info("")
    Mix.shell().info("#{from_store} from store, #{from_env} from env, #{missing} missing")
  end

  defp check_secret(name, max_name_len) do
    case Secrets.resolve(name) do
      {:ok, value, source} ->
        padded_name = String.pad_trailing(name, max_name_len)
        padded_source = String.pad_trailing(to_string(source), 7)
        Mix.shell().info("#{padded_name}  #{padded_source}  #{mask(value)}")
        source

      {:error, _reason} ->
        padded_name = String.pad_trailing(name, max_name_len)
        padded_source = String.pad_trailing("missing", 7)
        Mix.shell().info("#{padded_name}  #{padded_source}  ---")
        :missing
    end
  end

  defp mask(value) when byte_size(value) > 8 do
    first = String.slice(value, 0, 4)
    last = String.slice(value, -4, 4)
    "#{first}...#{last}"
  end

  defp mask(_value), do: "***"

  defp start_lemon_core! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
