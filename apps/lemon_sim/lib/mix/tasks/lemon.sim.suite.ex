defmodule Mix.Tasks.Lemon.Sim.Suite do
  @moduledoc """
  Run a LemonSim benchmark suite and write a leaderboard.

      mix lemon.sim.suite --scenario vending_bench --preset ci --seeds 11,22,33 --offline baseline,pressure --external-cmd "my-agent=python3 agent.py" --out /tmp/vb-suite

  `--external-cmd` accepts an optional `NAME=` prefix (letters, digits, `_`,
  `-`, `.`) giving the competitor a short leaderboard id; without it the
  command string itself is the id.

  Suite run adapters are currently available for `vending_bench`, `tcg_shop`,
  and `vending_bench_arena`. Other registered scorecards can be verified from
  artifact bundles, but do not yet have suite runners.
  """

  use Mix.Task

  @switches [
    scenario: :string,
    preset: :string,
    seeds: :string,
    offline: :string,
    model: :string,
    external_cmd: :string,
    out: :string,
    max_concurrency: :integer,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.shell().error("Invalid options: #{inspect(invalid)}")
        exit({:shutdown, 1})

      true ->
        ensure_runtime_started!()
        run_suite(opts)
    end
  end

  defp run_suite(opts) do
    spec = %{
      scenario: opts[:scenario],
      preset: opts[:preset],
      seeds: parse_seeds(opts[:seeds]),
      competitors: competitors(opts)
    }

    suite_opts =
      [suite_dir: opts[:out]]
      |> maybe_put(:max_concurrency, opts[:max_concurrency])

    case LemonSim.Bench.Suite.run(spec, suite_opts) do
      {:ok, %{leaderboard: leaderboard}} ->
        Mix.shell().info(leaderboard)

      {:error, reason} ->
        Mix.shell().error("Suite failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp parse_seeds(nil), do: []

  defp parse_seeds(value) do
    value
    |> split_csv()
    |> Enum.map(&String.to_integer/1)
  end

  defp competitors(opts) do
    offline =
      opts
      |> Keyword.get(:offline)
      |> split_csv()
      |> Enum.map(&%{id: &1, offline_strategy: &1})

    models =
      opts
      |> Keyword.get_values(:model)
      |> Enum.flat_map(&split_csv/1)
      |> Enum.map(&%{id: &1, model: &1})

    external =
      opts
      |> Keyword.get_values(:external_cmd)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&external_competitor/1)

    offline ++ models ++ external
  end

  # "my-agent=python3 agent.py" -> id "my-agent"; a bare command is its own id.
  defp external_competitor(value) do
    case Regex.run(~r/^([A-Za-z0-9_.-]+)=(.+)$/s, value) do
      [_, id, cmd] -> %{id: id, external_cmd: String.trim(cmd)}
      nil -> %{id: value, external_cmd: value}
    end
  end

  defp split_csv(nil), do: []

  defp split_csv(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp ensure_runtime_started! do
    Application.ensure_all_started(:lemon_sim)
    Application.ensure_all_started(:lemon_core)
  end
end
