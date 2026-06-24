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
    * `--sim-id` - Explicit simulation id for deterministic artifact names/content
    * `--worker-model` - Separate model for physical worker
    * `--preset` - Run preset: ci, paper, v2
    * `--arena` - Run deterministic Vending-Bench Arena mode
    * `--arena-agents` - Number of arena agents, up to 5 for the baseline
    * `--offline-strategy` - Deterministic strategy to run without model credentials (`baseline` or `pressure`)
    * `--artifact-dir` - Directory for offline run artifacts
    * `--deterministic-artifacts` - Pin artifact timestamps and path labels for byte-reproducible bundles
    * `--resume-artifact-dir` - Resume a live run from a checkpoint artifact directory
    * `--live-step-timeout-ms` - Outer timeout for one live operator step
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
    sim_id: :string,
    worker_model: :string,
    preset: :string,
    arena: :boolean,
    arena_agents: :integer,
    offline_strategy: :string,
    artifact_dir: :string,
    deterministic_artifacts: :boolean,
    resume_artifact_dir: :string,
    live_step_timeout_ms: :integer,
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
      |> apply_preset(opts[:preset])
      |> maybe_put(:max_days, opts[:max_days])
      |> maybe_put(:seed, opts[:seed])
      |> maybe_put(:sim_id, opts[:sim_id])
      |> maybe_put(:persist?, opts[:persist])
      |> maybe_put(:driver_max_turns, opts[:max_turns])
      |> maybe_put(:artifact_dir, opts[:artifact_dir])
      |> maybe_put(:deterministic_artifacts?, opts[:deterministic_artifacts])
      |> maybe_put(:live_step_timeout_ms, opts[:live_step_timeout_ms])

    result = run_mode(opts, run_opts)

    case result do
      {:ok, %{artifacts: artifacts, world: %{mode: "vending_bench_arena"}}}
      when is_map(artifacts) ->
        Mix.shell().info("Arena artifacts written to #{Path.dirname(artifacts.final_world)}")
        :ok

      {:ok, %{world: %{mode: "vending_bench_arena"}}} ->
        :ok

      {:ok, %{artifacts: artifacts}} ->
        Mix.shell().info("Offline artifacts written to #{Path.dirname(artifacts.final_world)}")
        :ok

      {:ok, _state} ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Simulation failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp run_mode(opts, run_opts) do
    cond do
      opts[:arena] ->
        strategy = opts[:offline_strategy] || "baseline"

        run_opts
        |> maybe_put(:arena_agents, opts[:arena_agents])
        |> then(&LemonSim.Examples.VendingBench.Arena.run_offline_strategy(strategy, &1))

      opts[:offline_strategy] ->
        LemonSim.Examples.VendingBench.run_offline_strategy(opts[:offline_strategy], run_opts)

      opts[:resume_artifact_dir] ->
        run_opts
        |> maybe_put_model(opts[:model])
        |> maybe_put_worker_model(opts[:worker_model])
        |> then(
          &LemonSim.Examples.VendingBench.resume_from_artifacts(opts[:resume_artifact_dir], &1)
        )

      true ->
        run_opts
        |> maybe_put_model(opts[:model])
        |> maybe_put_worker_model(opts[:worker_model])
        |> LemonSim.Examples.VendingBench.run()
    end
  end

  defp apply_preset(opts, nil), do: opts

  defp apply_preset(opts, "ci") do
    opts
    |> Keyword.put(:max_days, 7)
    |> Keyword.put(:driver_max_turns, 25)
    |> Keyword.put(:persist?, false)
  end

  defp apply_preset(opts, "paper") do
    opts
    |> Keyword.put(:max_days, 365)
    |> Keyword.put(:driver_max_turns, 2_000)
  end

  defp apply_preset(opts, "v2") do
    opts
    |> Keyword.put(:max_days, 365)
    |> Keyword.put(:driver_max_turns, 4_000)
  end

  defp apply_preset(_opts, preset) do
    Mix.shell().error("Unknown preset #{preset}. Expected one of: ci, paper, v2")
    exit({:shutdown, 1})
  end

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
            model = LemonSim.LLM.GameHelpers.Config.apply_provider_base_url(model, config)

            api_key =
              LemonSim.LLM.GameHelpers.Config.resolve_provider_api_key!(
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
            model = LemonSim.LLM.GameHelpers.Config.apply_provider_base_url(model, config)

            api_key =
              LemonSim.LLM.GameHelpers.Config.resolve_provider_api_key!(
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
