defmodule Mix.Tasks.Lemon.Sim.Legislature do
  use Mix.Task

  @shortdoc "Run the LemonSim Legislature self-play example"

  @moduledoc """
  Runs the LemonSim Legislature self-play example from the repo root.

      mix lemon.sim.legislature
      mix lemon.sim.legislature --no-persist --max-turns 20
      mix lemon.sim.legislature --model anthropic:claude-sonnet-4-20250514
      mix lemon.sim.legislature --player-count 6
  """

  @switches [
    persist: :boolean,
    max_turns: :integer,
    max_driver_turns: :integer,
    model: :string,
    player_count: :integer,
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
          |> maybe_put(:player_count, opts[:player_count])

        case LemonSim.Examples.Legislature.run(run_opts) do
          {:ok, _final_state} -> :ok
          {:error, reason} -> Mix.raise("legislature sim failed: #{inspect(reason)}")
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
    case provider |> String.trim() |> String.downcase() |> String.replace("-", "_") do
      "gemini" -> :google_gemini_cli
      "gemini_cli" -> :google_gemini_cli
      "openai_codex" -> :"openai-codex"
      normalized -> String.to_atom(normalized)
    end
  end

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.legislature [options]

    Options:
      --persist / --no-persist     Persist the final state (default: true)
      --max-turns N                Maximum turns before the sim stops
      --max-driver-turns N         Deprecated alias for --max-turns
      --model PROVIDER:MODEL       Override the configured default model
      --player-count N             Number of legislators (5-7, default: 5)
      --help                       Show this help
    """)
  end
end
