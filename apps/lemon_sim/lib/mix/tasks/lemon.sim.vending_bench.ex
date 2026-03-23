defmodule Mix.Tasks.Lemon.Sim.VendingBench do
  @moduledoc """
  Run the Vending Bench simulation.

  ## Usage

      mix lemon.sim.vending_bench [options]

  ## Options

    * `--model` - Model to use (e.g. google_gemini_cli:gemini-2.5-flash)
    * `--max-days` - Maximum number of simulated days (default: 30)
    * `--max-turns` - Maximum decision turns (default: 300)
    * `--seed` - Random seed for deterministic runs
    * `--worker-model` - Separate model for physical worker
    * `--persist` - Persist final state (default: true)
    * `--help` - Show this help
  """

  use Mix.Task

  @switches [
    persist: :boolean,
    max_turns: :integer,
    model: :string,
    max_days: :integer,
    seed: :integer,
    worker_model: :string,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      ensure_runtime_started!()
      run_simulation(opts)
    end
  end

  defp run_simulation(opts) do
    run_opts =
      []
      |> maybe_put(:max_days, opts[:max_days])
      |> maybe_put(:seed, opts[:seed])
      |> maybe_put(:persist?, opts[:persist])
      |> maybe_put(:driver_max_turns, opts[:max_turns])
      |> maybe_put_model(opts[:model])
      |> maybe_put_worker_model(opts[:worker_model])

    case LemonSim.Examples.VendingBench.run(run_opts) do
      {:ok, _state} ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Simulation failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_model(opts, nil), do: opts

  defp maybe_put_model(opts, model_str) do
    case resolve_model(model_str) do
      {:ok, model, api_key} ->
        opts
        |> Keyword.put(:model, model)
        |> Keyword.put(:stream_options, %{api_key: api_key})

      {:error, reason} ->
        Mix.shell().error("Could not resolve model #{model_str}: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp maybe_put_worker_model(opts, nil), do: opts

  defp maybe_put_worker_model(opts, model_str) do
    case resolve_model(model_str) do
      {:ok, model, api_key} ->
        opts
        |> Keyword.put(:physical_worker_model, model)
        |> Keyword.put(:physical_worker_stream_options, %{api_key: api_key})

      {:error, reason} ->
        Mix.shell().error("Could not resolve worker model #{model_str}: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp resolve_model(model_str) do
    config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

    case String.split(model_str, ":", parts: 2) do
      [provider_name, model_id] ->
        provider = normalize_provider(provider_name)

        case Ai.Models.get_model(provider, model_id) do
          %Ai.Types.Model{} = model ->
            model = LemonSim.GameHelpers.Config.apply_provider_base_url(model, config)

            api_key =
              LemonSim.GameHelpers.Config.resolve_provider_api_key!(
                provider,
                config,
                "vending_bench"
              )

            {:ok, model, api_key}

          nil ->
            {:error, :model_not_found}
        end

      [model_id] ->
        case Ai.Models.find_by_id(model_id) do
          %Ai.Types.Model{} = model ->
            model = LemonSim.GameHelpers.Config.apply_provider_base_url(model, config)

            api_key =
              LemonSim.GameHelpers.Config.resolve_provider_api_key!(
                model.provider,
                config,
                "vending_bench"
              )

            {:ok, model, api_key}

          nil ->
            {:error, :model_not_found}
        end
    end
  end

  @provider_aliases %{
    "gemini" => :google_gemini_cli,
    "gemini_cli" => :google_gemini_cli,
    "gemini-cli" => :google_gemini_cli,
    "openai_codex" => :"openai-codex"
  }

  defp normalize_provider(name) do
    normalized = name |> String.trim() |> String.downcase() |> String.replace("-", "_")
    Map.get(@provider_aliases, normalized, String.to_atom(normalized))
  end

  defp ensure_runtime_started! do
    Application.ensure_all_started(:lemon_sim)
    Application.ensure_all_started(:lemon_core)
  end
end
