defmodule LemonSim.Bench.Ratings do
  @moduledoc """
  Cross-suite Bradley-Terry ratings for LemonSim benchmark suites.

  Ratings are fit from aggregate pairwise outcomes across suite rankings. The
  fit is order-independent and uses a deterministic weak prior: every active
  competitor pair receives one pseudo draw, equivalent to `0.5` pseudo win for
  each side. Competitors with zero real comparisons are reported as unrated and
  are excluded from the fit.
  """

  alias LemonSim.Bench.Artifacts.AtomicFile
  alias LemonSim.LLM.Projectors.Toolkit

  @schema "lemon_sim.ratings.v1"
  @prior_half_win 0.5
  @prior_comparisons 1.0
  @max_iterations 10_000
  @tolerance 1.0e-12

  @type result :: %{
          required(:ratings) => map(),
          required(:leaderboard) => String.t()
        }

  @spec discover_suites(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def discover_suites(root) when is_binary(root) do
    cond do
      root == "" ->
        {:error, :missing_root}

      not File.dir?(root) ->
        {:error, {:root_not_found, root}}

      true ->
        suite_paths =
          [Path.join(root, "suite.json") | Path.wildcard(Path.join(root, "*/suite.json"))]
          |> Enum.filter(&File.regular?/1)

        suite_dirs =
          suite_paths
          |> Enum.map(&Path.dirname/1)
          |> normalize_suite_dirs()

        {:ok, suite_dirs}
    end
  end

  @spec rate([String.t()], keyword()) :: {:ok, result()} | {:error, term()}
  def rate(suite_dirs, _opts \\ []) when is_list(suite_dirs) do
    with {:ok, suite_dirs} <- normalize_input_dirs(suite_dirs),
         {:ok, inputs} <- read_inputs(suite_dirs) do
      competitor_ids = competitor_ids(inputs)
      matrix = pairwise_matrix(inputs, competitor_ids)
      stats = competitor_stats(competitor_ids, matrix, inputs)
      strengths = fit_strengths(competitor_ids, matrix, stats)
      competitors = competitor_rows(competitor_ids, stats, strengths)

      ratings = %{
        "schema_version" => @schema,
        "algorithm" => algorithm_artifact(),
        "generated_from" => Enum.map(inputs, &generated_from/1),
        "competitors" => competitors,
        "pairwise" => matrix
      }

      {:ok, %{ratings: ratings, leaderboard: render_leaderboard(ratings)}}
    end
  end

  @spec write([String.t()], String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def write(suite_dirs, out_dir, opts \\ []) when is_list(suite_dirs) and is_binary(out_dir) do
    with {:ok, %{ratings: ratings, leaderboard: leaderboard} = result} <- rate(suite_dirs, opts) do
      File.mkdir_p!(out_dir)
      AtomicFile.write!(Path.join(out_dir, "ratings.json"), Toolkit.stable_json(ratings) <> "\n")
      AtomicFile.write!(Path.join(out_dir, "ratings.md"), leaderboard)
      {:ok, result}
    end
  end

  @spec render_leaderboard(map()) :: String.t()
  def render_leaderboard(ratings) when is_map(ratings) do
    competitors = ratings["competitors"] || []
    generated_from = ratings["generated_from"] || []

    header = [
      "# LemonSim Ratings Leaderboard",
      "",
      "Suites: #{length(generated_from)}",
      "Algorithm: Bradley-Terry MLE with one pseudo draw per active pair.",
      "",
      "| Rank | Competitor | Rating | Comparisons | W-L-D | Suites |",
      "|---:|---|---:|---:|---:|---:|"
    ]

    rows =
      competitors
      |> Enum.with_index(1)
      |> Enum.map(fn {competitor, index} ->
        rank = if competitor["rated"], do: index, else: "-"

        [
          rank,
          competitor["competitor"],
          format_rating(competitor["rating"]),
          competitor["n_comparisons"],
          "#{format_count(competitor["wins"])}-#{format_count(competitor["losses"])}-#{format_count(competitor["draws"])}",
          competitor["suites_included"]
        ]
        |> then(fn row -> "| #{Enum.join(row, " | ")} |" end)
      end)

    (header ++ rows)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp normalize_input_dirs(suite_dirs) do
    suite_dirs = normalize_suite_dirs(suite_dirs)

    if suite_dirs == [] do
      {:error, :no_suites}
    else
      {:ok, suite_dirs}
    end
  end

  defp normalize_suite_dirs(suite_dirs) do
    suite_dirs
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp read_inputs(suite_dirs) do
    suite_dirs
    |> Enum.reduce_while({:ok, []}, fn suite_dir, {:ok, inputs} ->
      case read_input(suite_dir) do
        {:ok, input} -> {:cont, {:ok, [input | inputs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      error -> error
    end
  end

  defp read_input(suite_dir) do
    path = Path.join(suite_dir, "suite.json")

    with {:ok, body} <- File.read(path),
         {:ok, suite} <- Jason.decode(body),
         :ok <- validate_suite(suite, suite_dir) do
      {:ok,
       %{
         "suite_dir" => Path.expand(suite_dir),
         "suite" => suite,
         "scenario" => get_in(suite, ["spec", "scenario"]),
         "preset" => get_in(suite, ["spec", "preset"]),
         "primary_metric" => suite["primary_metric"]
       }}
    else
      {:error, reason} -> {:error, {:read_suite_failed, path, reason}}
      {:invalid_suite, reason} -> {:error, {:invalid_suite, path, reason}}
    end
  end

  defp validate_suite(suite, suite_dir) do
    cond do
      not is_map(suite) ->
        {:invalid_suite, :not_a_map}

      suite["schema_version"] != "lemon_sim.suite.v1" ->
        {:invalid_suite, {:unsupported_schema, suite["schema_version"]}}

      not is_map(suite["spec"]) ->
        {:invalid_suite, :missing_spec}

      not is_map(suite["primary_metric"]) ->
        {:invalid_suite, :missing_primary_metric}

      not is_list(suite["rankings"]) ->
        {:invalid_suite, :missing_rankings}

      not File.regular?(Path.join(suite_dir, "suite.json")) ->
        {:invalid_suite, :missing_suite_json}

      true ->
        case direction(suite["primary_metric"]) do
          {:ok, _direction} -> :ok
          {:error, reason} -> {:invalid_suite, reason}
        end
    end
  end

  defp competitor_ids(inputs) do
    inputs
    |> Enum.flat_map(fn input ->
      suite = input["suite"]
      spec_ids = spec_competitor_ids(suite)
      ranking_ids = Enum.map(suite["rankings"] || [], & &1["competitor"])
      spec_ids ++ ranking_ids
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp spec_competitor_ids(suite) do
    suite
    |> get_in(["spec", "competitors"])
    |> case do
      competitors when is_list(competitors) -> Enum.map(competitors, & &1["id"])
      _ -> []
    end
  end

  defp pairwise_matrix(inputs, competitor_ids) do
    base = empty_matrix(competitor_ids)

    Enum.reduce(inputs, base, fn input, matrix ->
      suite = input["suite"]

      {:ok, direction} = direction(suite["primary_metric"])
      add_suite_outcomes(matrix, suite, competitor_ids, direction)
    end)
  end

  defp empty_matrix(competitor_ids) do
    Map.new(competitor_ids, fn competitor ->
      opponents =
        competitor_ids
        |> Enum.reject(&(&1 == competitor))
        |> Map.new(&{&1, empty_pair()})

      {competitor, opponents}
    end)
  end

  defp empty_pair do
    %{"wins" => 0, "losses" => 0, "draws" => 0, "n" => 0}
  end

  defp add_suite_outcomes(matrix, suite, competitor_ids, direction) do
    values_by_competitor = suite_values_by_competitor(suite)

    competitor_ids
    |> combinations()
    |> Enum.reduce(matrix, fn {left, right}, acc ->
      left_values = Map.get(values_by_competitor, left, %{})
      right_values = Map.get(values_by_competitor, right, %{})

      left_values
      |> common_seeds(right_values)
      |> Enum.reduce(acc, fn seed, seed_acc ->
        compare_values(left_values[seed], right_values[seed], direction)
        |> add_outcome(seed_acc, left, right)
      end)
    end)
  end

  defp suite_values_by_competitor(suite) do
    suite
    |> Map.get("rankings", [])
    |> Enum.map(fn ranking ->
      values =
        ranking
        |> Map.get("values_by_seed", %{})
        |> Enum.filter(fn {_seed, value} -> is_number(value) end)
        |> Map.new(fn {seed, value} -> {to_string(seed), value} end)

      {ranking["competitor"], values}
    end)
    |> Enum.filter(fn {competitor, _values} -> is_binary(competitor) end)
    |> Map.new()
  end

  defp common_seeds(left_values, right_values) do
    left_values
    |> Map.keys()
    |> MapSet.new()
    |> MapSet.intersection(right_values |> Map.keys() |> MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp compare_values(left, right, _direction) when left == right, do: :draw
  defp compare_values(left, right, :maximize) when left > right, do: :left
  defp compare_values(_left, _right, :maximize), do: :right
  defp compare_values(left, right, :minimize) when left < right, do: :left
  defp compare_values(_left, _right, :minimize), do: :right

  defp add_outcome(:left, matrix, left, right), do: increment_pair(matrix, left, right, :win)
  defp add_outcome(:right, matrix, left, right), do: increment_pair(matrix, right, left, :win)
  defp add_outcome(:draw, matrix, left, right), do: increment_pair(matrix, left, right, :draw)

  defp increment_pair(matrix, winner, loser, :win) do
    matrix
    |> update_pair(winner, loser, fn pair ->
      pair
      |> Map.update!("wins", &(&1 + 1))
      |> Map.update!("n", &(&1 + 1))
    end)
    |> update_pair(loser, winner, fn pair ->
      pair
      |> Map.update!("losses", &(&1 + 1))
      |> Map.update!("n", &(&1 + 1))
    end)
  end

  defp increment_pair(matrix, left, right, :draw) do
    matrix
    |> update_pair(left, right, fn pair ->
      pair
      |> Map.update!("draws", &(&1 + 1))
      |> Map.update!("n", &(&1 + 1))
    end)
    |> update_pair(right, left, fn pair ->
      pair
      |> Map.update!("draws", &(&1 + 1))
      |> Map.update!("n", &(&1 + 1))
    end)
  end

  defp update_pair(matrix, competitor, opponent, fun) do
    update_in(matrix, [competitor, opponent], fun)
  end

  defp competitor_stats(competitor_ids, matrix, inputs) do
    suites_by_competitor = suites_by_competitor(inputs)

    Map.new(competitor_ids, fn competitor ->
      pairs = Map.values(matrix[competitor] || %{})

      stats = %{
        "wins" => Enum.sum(Enum.map(pairs, & &1["wins"])),
        "losses" => Enum.sum(Enum.map(pairs, & &1["losses"])),
        "draws" => Enum.sum(Enum.map(pairs, & &1["draws"])),
        "n_comparisons" => Enum.sum(Enum.map(pairs, & &1["n"])),
        "suites_included" => Map.get(suites_by_competitor, competitor, 0)
      }

      {competitor, stats}
    end)
  end

  defp suites_by_competitor(inputs) do
    inputs
    |> Enum.reduce(%{}, fn input, acc ->
      input["suite"]
      |> spec_competitor_ids()
      |> Enum.uniq()
      |> Enum.reduce(acc, fn competitor, inner_acc ->
        Map.update(inner_acc, competitor, 1, &(&1 + 1))
      end)
    end)
  end

  defp fit_strengths(competitor_ids, matrix, stats) do
    active_ids =
      competitor_ids
      |> Enum.filter(fn competitor -> get_in(stats, [competitor, "n_comparisons"]) > 0 end)

    if length(active_ids) < 2 do
      %{}
    else
      do_fit_strengths(active_ids, matrix)
    end
  end

  defp do_fit_strengths(active_ids, matrix) do
    initial = Map.new(active_ids, &{&1, 1.0})

    Enum.reduce_while(1..@max_iterations, initial, fn _iteration, strengths ->
      updated =
        Map.new(active_ids, fn competitor ->
          numerator =
            active_ids
            |> Enum.reject(&(&1 == competitor))
            |> Enum.reduce(0.0, fn opponent, acc ->
              pair = matrix[competitor][opponent]
              acc + pair["wins"] + pair["draws"] * 0.5 + @prior_half_win
            end)

          denominator =
            active_ids
            |> Enum.reject(&(&1 == competitor))
            |> Enum.reduce(0.0, fn opponent, acc ->
              pair = matrix[competitor][opponent]
              n = pair["n"] + @prior_comparisons
              acc + n / (strengths[competitor] + strengths[opponent])
            end)

          {competitor, numerator / denominator}
        end)
        |> normalize_strengths()

      if max_delta(strengths, updated) < @tolerance do
        {:halt, updated}
      else
        {:cont, updated}
      end
    end)
  end

  defp normalize_strengths(strengths) do
    count = map_size(strengths)
    total = strengths |> Map.values() |> Enum.sum()

    Map.new(strengths, fn {competitor, strength} ->
      {competitor, strength * count / total}
    end)
  end

  defp max_delta(left, right) do
    left
    |> Map.keys()
    |> Enum.map(fn key -> abs(left[key] - right[key]) end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp competitor_rows(competitor_ids, stats, strengths) do
    geometric_mean = geometric_mean(strengths)

    competitor_ids
    |> Enum.map(fn competitor ->
      row_stats = stats[competitor]
      strength = strengths[competitor]
      rating = rating(strength, geometric_mean)

      %{
        "competitor" => competitor,
        "rating" => rating,
        "rated" => rating != nil,
        "n_comparisons" => row_stats["n_comparisons"],
        "wins" => row_stats["wins"],
        "losses" => row_stats["losses"],
        "draws" => row_stats["draws"],
        "suites_included" => row_stats["suites_included"]
      }
    end)
    |> Enum.sort_by(fn row ->
      case row["rating"] do
        nil -> {1, row["competitor"]}
        rating -> {0, -rating, row["competitor"]}
      end
    end)
  end

  defp geometric_mean(strengths) when map_size(strengths) == 0, do: nil

  defp geometric_mean(strengths) do
    strengths
    |> Map.values()
    |> Enum.map(&:math.log/1)
    |> Enum.sum()
    |> Kernel./(map_size(strengths))
    |> :math.exp()
  end

  defp rating(nil, _geometric_mean), do: nil
  defp rating(_strength, nil), do: nil

  defp rating(strength, geometric_mean) do
    (1500.0 + 400.0 * (:math.log(strength / geometric_mean) / :math.log(10.0)))
    |> Float.round(6)
  end

  defp generated_from(input) do
    %{
      "suite_dir" => input["suite_dir"],
      "scenario" => input["scenario"],
      "preset" => input["preset"],
      "primary_metric" => input["primary_metric"]
    }
  end

  defp algorithm_artifact do
    %{
      "name" => "bradley_terry_mle_fixed_point",
      "rating_base" => 1500,
      "rating_scale" => 400,
      "prior" => "one pseudo draw per active competitor pair",
      "prior_half_win_per_pair" => @prior_half_win,
      "prior_comparisons_per_pair" => @prior_comparisons,
      "max_iterations" => @max_iterations,
      "tolerance" => @tolerance
    }
  end

  defp direction(%{"direction" => "maximize"}), do: {:ok, :maximize}
  defp direction(%{"direction" => "minimize"}), do: {:ok, :minimize}
  defp direction(%{"direction" => :maximize}), do: {:ok, :maximize}
  defp direction(%{"direction" => :minimize}), do: {:ok, :minimize}
  defp direction(_metric), do: {:error, :invalid_primary_metric_direction}

  defp combinations([]), do: []
  defp combinations([_]), do: []

  defp combinations([head | tail]) do
    Enum.map(tail, &{head, &1}) ++ combinations(tail)
  end

  defp format_rating(nil), do: "unrated"

  defp format_rating(value) when is_number(value) do
    :erlang.float_to_binary(value / 1, decimals: 2)
  end

  defp format_count(value) when is_integer(value), do: Integer.to_string(value)
  defp format_count(value), do: to_string(value)
end
