defmodule LemonSim.Bench.Suite do
  @moduledoc """
  Runs benchmark suites and writes model leaderboards.
  """

  alias LemonCore.Config.Modular
  alias LemonSim.Bench.Artifacts.{AtomicFile, Verifier}
  alias LemonSim.Bench.Scorecard.Registry
  alias LemonSim.Examples.{TcgShop, VendingBench}
  alias LemonSim.LLM.GameHelpers.Config
  alias LemonSim.LLM.Projectors.Toolkit

  @schema "lemon_sim.suite.v1"
  @usage_keys ~w(input_tokens output_tokens cache_read_tokens cache_write_tokens decisions)

  def run(spec, opts \\ []) when is_map(spec) and is_list(opts) do
    with {:ok, suite_dir} <- suite_dir(opts),
         {:ok, spec} <- normalize_spec(spec),
         {:ok, run_results} <- run_matrix(spec, suite_dir, opts),
         {:ok, suite} <- build_suite(spec, run_results) do
      write_suite!(suite_dir, suite)
      {:ok, %{suite_dir: suite_dir, suite: suite, leaderboard: render_leaderboard(suite)}}
    end
  end

  def write_leaderboard(suite_dir, opts \\ []) when is_binary(suite_dir) and is_list(opts) do
    result =
      if Keyword.get(opts, :recompute, false) do
        recompute(suite_dir)
      else
        read_suite(suite_dir)
      end

    with {:ok, suite} <- result do
      leaderboard = render_leaderboard(suite)
      AtomicFile.write!(Path.join(suite_dir, "leaderboard.md"), leaderboard)
      {:ok, leaderboard}
    end
  end

  def recompute(suite_dir) when is_binary(suite_dir) do
    with {:ok, suite} <- read_suite(suite_dir),
         {:ok, spec} <- normalize_spec(suite["spec"] || suite[:spec]),
         {:ok, run_results} <-
           recompute_runs(spec, suite["runs"] || suite[:runs] || [], suite_dir),
         {:ok, recomputed} <- build_suite(spec, run_results) do
      write_suite!(suite_dir, recomputed)
      {:ok, recomputed}
    end
  end

  def read_suite(suite_dir) when is_binary(suite_dir) do
    path = Path.join(suite_dir, "suite.json")

    with {:ok, body} <- File.read(path),
         {:ok, suite} <- Jason.decode(body) do
      {:ok, suite}
    else
      {:error, reason} -> {:error, {:read_suite_failed, path, reason}}
    end
  end

  def build_suite(spec, run_results) when is_map(spec) and is_list(run_results) do
    with {:ok, metric} <- primary_metric(spec["scenario"]),
         {:ok, rankings} <- rankings(spec, run_results, metric) do
      suite = %{
        schema_version: @schema,
        spec: spec,
        primary_metric: metric_artifact(metric),
        runs: Enum.sort_by(run_results, &(&1["index"] || &1[:index] || 0)),
        rankings: rankings,
        failures: failures(run_results)
      }

      {:ok, suite}
    end
  end

  def metric_value(scorecard, key) when is_binary(key), do: metric_value(scorecard, [key])

  def metric_value(scorecard, keys) when is_list(keys) do
    value =
      Enum.reduce_while(keys, scorecard, fn key, current ->
        case fetch_key(current, key) do
          {:ok, value} -> {:cont, value}
          :error -> {:halt, nil}
        end
      end)

    if is_number(value), do: {:ok, value}, else: {:error, {:metric_not_numeric, keys, value}}
  end

  def render_leaderboard(suite) when is_map(suite) do
    spec = suite["spec"] || suite[:spec] || %{}
    rankings = suite["rankings"] || suite[:rankings] || []
    failures = suite["failures"] || suite[:failures] || []
    metric = suite["primary_metric"] || suite[:primary_metric] || %{}
    metric_name = metric["name"] || metric[:name] || "metric"
    direction = metric["direction"] || metric[:direction] || "maximize"
    preset = spec["preset"] || spec[:preset] || "default"
    seeds = spec["seeds"] || spec[:seeds] || []

    header = [
      "# LemonSim Suite Leaderboard",
      "",
      "Scenario: `#{spec["scenario"] || spec[:scenario]}`",
      "Preset: `#{preset}`",
      "Seeds: #{length(seeds)}",
      "Metric: `#{metric_name}` (#{direction})",
      "",
      "All included runs are manifest hash and scorecard verified.",
      "",
      "| Rank | Competitor | Mean #{metric_name} (#{direction}) | Per-seed values | Tokens | Cost |",
      "|---:|---|---:|---|---:|---:|"
    ]

    ranking_rows =
      Enum.map(rankings, fn ranking ->
        [
          ranking["rank"] || ranking[:rank],
          ranking["competitor"] || ranking[:competitor],
          format_number(ranking["mean"] || ranking[:mean]),
          format_values(ranking["values_by_seed"] || ranking[:values_by_seed] || %{}),
          format_integer(total_tokens(ranking["usage_totals"] || ranking[:usage_totals] || %{})),
          format_cost(
            get_key(ranking["usage_totals"] || ranking[:usage_totals] || %{}, "cost_usd")
          )
        ]
        |> then(fn row -> "| #{Enum.join(row, " | ")} |" end)
      end)

    failure_section =
      if failures == [] do
        []
      else
        [
          "",
          "## Failures",
          "",
          "Unverified runs are excluded from rankings.",
          "",
          "| Competitor | Seed | Error |",
          "|---|---:|---|"
          | Enum.map(failures, fn failure ->
              "| #{failure["competitor"] || failure[:competitor]} | #{failure["seed"] || failure[:seed]} | `#{failure["error"] || failure[:error]}` |"
            end)
        ]
      end

    (header ++ ranking_rows ++ failure_section)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp suite_dir(opts) do
    case Keyword.get(opts, :suite_dir) || Keyword.get(opts, :out) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:error, :missing_suite_dir}
    end
  end

  defp normalize_spec(spec) do
    spec = stringify_keys(spec)
    scenario = spec["scenario"]
    preset = spec["preset"]
    seeds = spec["seeds"] || []
    competitors = spec["competitors"] || []

    cond do
      not is_binary(scenario) or scenario == "" ->
        {:error, :missing_scenario}

      not is_list(seeds) or seeds == [] or not Enum.all?(seeds, &is_integer/1) ->
        {:error, :invalid_seeds}

      not is_list(competitors) or competitors == [] ->
        {:error, :invalid_competitors}

      true ->
        competitors = Enum.map(competitors, &normalize_competitor!/1)

        {:ok,
         %{
           "scenario" => scenario,
           "preset" => preset,
           "seeds" => seeds,
           "competitors" => competitors
         }}
    end
  rescue
    error -> {:error, {:invalid_suite_spec, error}}
  end

  defp normalize_competitor!(competitor) do
    competitor = stringify_keys(competitor)
    id = competitor["id"] || competitor["offline_strategy"] || competitor["model"]

    cond do
      not is_binary(id) or id == "" ->
        raise ArgumentError, "competitor id is required"

      is_binary(competitor["offline_strategy"]) ->
        %{"id" => id, "offline_strategy" => competitor["offline_strategy"]}

      is_binary(competitor["model"]) ->
        %{"id" => id, "model" => competitor["model"]}

      true ->
        raise ArgumentError, "competitor must have offline_strategy or model"
    end
  end

  defp run_matrix(spec, suite_dir, opts) do
    File.mkdir_p!(suite_dir)
    jobs = jobs(spec, suite_dir)
    max_concurrency = Keyword.get(opts, :max_concurrency, 1)

    results =
      if max_concurrency > 1 do
        jobs
        |> Task.async_stream(&run_job/1,
          max_concurrency: max_concurrency,
          ordered: true,
          timeout: :infinity
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, reason} -> failed_job(nil, nil, nil, nil, {:task_exit, reason})
        end)
      else
        Enum.map(jobs, &run_job/1)
      end

    {:ok, Enum.sort_by(results, & &1["index"])}
  end

  defp jobs(spec, suite_dir) do
    for {competitor, competitor_index} <- Enum.with_index(spec["competitors"]),
        {seed, seed_index} <- Enum.with_index(spec["seeds"]) do
      index = competitor_index * length(spec["seeds"]) + seed_index

      artifact_dir =
        Path.join([suite_dir, "runs", safe_path_id(competitor["id"]), to_string(seed)])

      sim_id = sim_id(spec["scenario"], competitor["id"], seed)

      %{
        index: index,
        spec: spec,
        competitor: competitor,
        seed: seed,
        sim_id: sim_id,
        artifact_dir: artifact_dir,
        relative_artifact_dir:
          Path.join(["runs", safe_path_id(competitor["id"]), to_string(seed)])
      }
    end
  end

  defp run_job(job) do
    run_opts = [
      seed: job.seed,
      sim_id: job.sim_id,
      artifact_dir: job.artifact_dir,
      deterministic_artifacts?: true
    ]

    case run_scenario(job.spec, job.competitor, run_opts) do
      {:ok, _result} -> verify_job(job)
      {:error, reason} -> failed_job(job, false, job.sim_id, job.relative_artifact_dir, reason)
    end
  end

  defp recompute_runs(spec, runs, suite_dir) do
    results =
      runs
      |> Enum.sort_by(&(&1["index"] || &1[:index] || 0))
      |> Enum.map(fn run ->
        job = %{
          index: run["index"] || run[:index],
          spec: spec,
          competitor: competitor_spec(spec, run["competitor"] || run[:competitor]),
          seed: run["seed"] || run[:seed],
          sim_id: run["sim_id"] || run[:sim_id],
          artifact_dir: Path.join(suite_dir, run["artifact_dir"] || run[:artifact_dir]),
          relative_artifact_dir: run["artifact_dir"] || run[:artifact_dir]
        }

        verify_job(job)
      end)

    {:ok, results}
  end

  defp verify_job(job) do
    with {:ok, verified} <- Verifier.verify_run(job.artifact_dir),
         {:ok, metric} <- primary_metric(job.spec["scenario"]),
         {:ok, value} <- metric_value(verified.scorecard, metric.key),
         {:ok, usage} <- read_usage(job.artifact_dir) do
      %{
        "index" => job.index,
        "scenario" => job.spec["scenario"],
        "competitor" => job.competitor["id"],
        "competitor_spec" => job.competitor,
        "seed" => job.seed,
        "sim_id" => get_in(verified.manifest, ["sim", "id"]) && job.sim_id,
        "artifact_dir" => job.relative_artifact_dir,
        "verified" => true,
        "metric" => value,
        "usage_totals" => usage["totals"] || %{}
      }
    else
      {:error, reason} -> failed_job(job, false, job.sim_id, job.relative_artifact_dir, reason)
    end
  end

  defp failed_job(nil, _verified, _sim_id, _artifact_dir, reason) do
    %{
      "index" => -1,
      "scenario" => nil,
      "competitor" => nil,
      "seed" => nil,
      "sim_id" => nil,
      "artifact_dir" => nil,
      "verified" => false,
      "metric" => nil,
      "usage_totals" => zero_usage_totals(),
      "error" => inspect(reason)
    }
  end

  defp failed_job(job, _verified, sim_id, artifact_dir, reason) do
    %{
      "index" => job.index,
      "scenario" => job.spec["scenario"],
      "competitor" => job.competitor["id"],
      "competitor_spec" => job.competitor,
      "seed" => job.seed,
      "sim_id" => sim_id,
      "artifact_dir" => artifact_dir,
      "verified" => false,
      "metric" => nil,
      "usage_totals" => zero_usage_totals(),
      "error" => inspect(reason)
    }
  end

  defp run_scenario(spec, competitor, opts) do
    run_opts =
      spec["scenario"]
      |> preset_opts(spec["preset"])
      |> Keyword.merge(opts)

    cond do
      offline = competitor["offline_strategy"] ->
        run_offline(spec["scenario"], offline, run_opts)

      model_id = competitor["model"] ->
        run_live(spec["scenario"], model_id, run_opts)
    end
  end

  defp run_offline("vending_bench", strategy, opts),
    do: VendingBench.run_offline_strategy(strategy, opts)

  defp run_offline("tcg_shop", strategy, opts), do: TcgShop.run_offline_strategy(strategy, opts)

  defp run_offline("vending_bench_arena", strategy, opts) do
    VendingBench.Arena.run_offline_strategy(strategy, opts)
  end

  defp run_offline(scenario, _strategy, _opts),
    do: {:error, {:unsupported_suite_scenario, scenario}}

  defp run_live("vending_bench", model_id, opts) do
    with {:ok, model, api_key} <- resolve_model(model_id) do
      opts
      |> Keyword.put(:model, model)
      |> Keyword.put(:stream_options, %{api_key: api_key})
      |> VendingBench.run()
    end
  end

  defp run_live("tcg_shop", model_id, opts) do
    with {:ok, model, api_key} <- resolve_model(model_id) do
      case TcgShop.run(Keyword.merge(opts, model: model, stream_options: %{api_key: api_key})) do
        {:ok, state} ->
          LemonSim.Examples.TcgShop.Artifacts.write_run_artifacts(state, [], [], opts)

        error ->
          error
      end
    end
  end

  defp run_live(scenario, _model_id, _opts),
    do: {:error, {:unsupported_live_suite_scenario, scenario}}

  defp preset_opts("vending_bench", "ci"),
    do: [max_days: 7, driver_max_turns: 25, persist?: false]

  defp preset_opts("vending_bench", "paper"), do: [max_days: 365, driver_max_turns: 2_000]
  defp preset_opts("vending_bench", "v2"), do: [max_days: 365, driver_max_turns: 4_000]
  defp preset_opts("tcg_shop", "ci"), do: [max_days: 5, driver_max_turns: 20, persist?: false]
  defp preset_opts("tcg_shop", "paper"), do: [max_days: 90, driver_max_turns: 200]

  defp preset_opts("tcg_shop", "stress"),
    do: [max_days: 14, driver_max_turns: 80, persist?: false]

  defp preset_opts(_scenario, nil), do: []

  defp preset_opts(scenario, preset),
    do: raise(ArgumentError, "unknown preset #{preset} for #{scenario}")

  defp primary_metric(scenario) do
    case Registry.fetch(scenario) do
      {:ok, module} ->
        %{key: key, direction: direction} = module.primary_metric()
        {:ok, %{key: List.wrap(key), direction: direction}}

      :error ->
        {:error, {:unregistered_scorecard, scenario}}
    end
  end

  defp rankings(spec, run_results, metric) do
    competitor_index =
      spec["competitors"]
      |> Enum.with_index()
      |> Map.new(fn {competitor, index} -> {competitor["id"], index} end)

    rankings =
      run_results
      |> Enum.group_by(& &1["competitor"])
      |> Enum.flat_map(fn {competitor_id, results} ->
        verified = Enum.filter(results, & &1["verified"])

        if verified == [] do
          []
        else
          values = Enum.map(verified, & &1["metric"])

          [
            %{
              "competitor" => competitor_id,
              "mean" => Enum.sum(values) / length(values),
              "min" => Enum.min(values),
              "max" => Enum.max(values),
              "values_by_seed" =>
                verified
                |> Enum.sort_by(& &1["seed"])
                |> Map.new(fn result -> {to_string(result["seed"]), result["metric"]} end),
              "usage_totals" => aggregate_usage(verified),
              "included_runs" => length(verified),
              "failed_runs" => length(results) - length(verified)
            }
          ]
        end
      end)
      |> Enum.sort_by(fn ranking ->
        order_metric =
          case metric.direction do
            :maximize -> -ranking["mean"]
            :minimize -> ranking["mean"]
          end

        {order_metric, Map.fetch!(competitor_index, ranking["competitor"])}
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {ranking, rank} -> Map.put(ranking, "rank", rank) end)

    {:ok, rankings}
  end

  defp aggregate_usage(results) do
    totals = Enum.map(results, &(&1["usage_totals"] || %{}))

    base =
      Map.new(@usage_keys, fn key ->
        {key, Enum.reduce(totals, 0, fn usage, acc -> acc + (get_key(usage, key) || 0) end)}
      end)

    cost =
      if Enum.any?(totals, &is_nil(get_key(&1, "cost_usd"))) do
        nil
      else
        totals
        |> Enum.reduce(0.0, fn usage, acc -> acc + (get_key(usage, "cost_usd") || 0.0) end)
        |> Float.round(6)
      end

    Map.put(base, "cost_usd", cost)
  end

  defp failures(run_results) do
    run_results
    |> Enum.reject(& &1["verified"])
    |> Enum.map(fn result ->
      %{
        "competitor" => result["competitor"],
        "seed" => result["seed"],
        "artifact_dir" => result["artifact_dir"],
        "error" => result["error"]
      }
    end)
  end

  defp write_suite!(suite_dir, suite) do
    File.mkdir_p!(suite_dir)
    AtomicFile.write!(Path.join(suite_dir, "suite.json"), Toolkit.stable_json(suite) <> "\n")
    AtomicFile.write!(Path.join(suite_dir, "leaderboard.md"), render_leaderboard(suite))
  end

  defp read_usage(artifact_dir) do
    path = Path.join(artifact_dir, "usage.json")

    with {:ok, body} <- File.read(path),
         {:ok, usage} <- Jason.decode(body) do
      {:ok, usage}
    else
      {:error, reason} -> {:error, {:read_usage_failed, path, reason}}
    end
  end

  defp resolve_model(model_id) do
    config = Modular.load(project_dir: File.cwd!())

    case Config.resolve_model_spec(nil, model_id) do
      %Ai.Types.Model{} = model ->
        model = Config.apply_provider_base_url(model, config)
        api_key = Config.resolve_provider_api_key!(model.provider, config, "suite")
        {:ok, model, api_key}

      nil ->
        {:error, {:model_not_found, model_id}}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp fetch_key(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      is_binary(key) and Map.has_key?(map, String.to_atom(key)) ->
        {:ok, Map.fetch!(map, String.to_atom(key))}

      true ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  defp fetch_key(_value, _key), do: :error

  defp competitor_spec(spec, competitor_id) do
    Enum.find(spec["competitors"], &(&1["id"] == competitor_id)) ||
      %{"id" => competitor_id}
  end

  defp metric_artifact(metric) do
    %{
      "key" => metric.key,
      "name" => Enum.join(metric.key, "."),
      "direction" => Atom.to_string(metric.direction)
    }
  end

  defp zero_usage_totals do
    Map.put(Map.new(@usage_keys, &{&1, 0}), "cost_usd", nil)
  end

  defp get_key(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp get_key(_map, _key), do: nil

  defp total_tokens(usage) do
    Enum.reduce(~w(input_tokens output_tokens cache_read_tokens cache_write_tokens), 0, fn key,
                                                                                           acc ->
      acc + (get_key(usage, key) || 0)
    end)
  end

  defp format_values(values) do
    values
    |> Enum.sort_by(fn {seed, _value} -> seed end)
    |> Enum.map(fn {seed, value} -> "#{seed}: #{format_number(value)}" end)
    |> Enum.join(", ")
  end

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_number(value) when is_float(value) do
    :erlang.float_to_binary(value, [:compact, decimals: 2])
  end

  defp format_number(value), do: to_string(value)

  defp format_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp format_integer(value), do: to_string(value)

  defp format_cost(nil), do: "unknown"

  defp format_cost(value) when is_number(value),
    do: "$#{:erlang.float_to_binary(value / 1, decimals: 4)}"

  defp format_cost(value), do: to_string(value)

  defp safe_path_id(id) do
    id
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "competitor"
      safe -> safe
    end
  end

  defp sim_id(scenario, competitor, seed) do
    [scenario, safe_path_id(competitor), seed]
    |> Enum.join("_")
    |> then(&"suite_#{&1}")
  end
end
