defmodule Mix.Tasks.Lemon.Sim.Skirmish do
  use Mix.Task

  @shortdoc "Run the LemonSim skirmish self-play example"

  @moduledoc """
  Runs the LemonSim skirmish example from the repo root.

      mix lemon.sim.skirmish
      mix lemon.sim.skirmish --no-persist --max-turns 12
      mix lemon.sim.skirmish --model anthropic:claude-sonnet-4-20250514
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        print_help()

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      true ->
        ensure_runtime_started!()

        run_opts =
          []
          |> maybe_put(:persist?, opts[:persist])
          |> maybe_put(:driver_max_turns, opts[:max_turns] || opts[:max_driver_turns])
          |> maybe_put(:model, resolve_model(opts[:model]))

        case LemonSim.Examples.Skirmish.run(run_opts) do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("skirmish sim failed: #{inspect(reason)}")
        end
    end
  end

  defp ensure_runtime_started! do
    case Application.ensure_all_started(:lemon_sim) do
      {:ok, _started} -> :ok
      {:error, reason} -> Mix.raise("failed to start lemon_sim runtime: #{inspect(reason)}")
    end
  end

  defp resolve_model(nil), do: nil
  defp resolve_model(""), do: nil

  defp resolve_model(model_spec) when is_binary(model_spec) do
    trimmed = String.trim(model_spec)

    case String.split(trimmed, ":", parts: 2) do
      [provider, model_id] ->
        provider
        |> normalize_provider()
        |> then(fn provider_atom ->
          Ai.Models.get_model(provider_atom, model_id) ||
            Mix.raise("unknown model #{inspect(model_id)} for provider #{inspect(provider)}")
        end)

      [_model_id] ->
        Ai.Models.find_by_id(trimmed) || Mix.raise("unknown model #{inspect(trimmed)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_provider(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.skirmish [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --help                       Show this help
    """)
  end
end
