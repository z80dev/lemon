defmodule LemonSim.Bench.League do
  @moduledoc """
  Generic persistent multi-game league: match planning, per-game records,
  and per-model / per-role standings with Bradley-Terry ratings.

  The league is file-backed and deterministic. A league directory holds one
  scenario's games:

    * `games/<game_id>.json` — one record per finished game (schema
      `lemon_sim.league.v1.game`), produced from the final world via a
      scenario adapter (`LemonSim.Bench.League.Adapter`).
    * `league.json` — aggregated standings recomputed from every game record
      (schema `lemon_sim.league.v1`). Byte-deterministic for a given set of
      game records.
    * `league.md` — human-readable leaderboard rendered from the same data.

  Ratings use the shared Bradley-Terry fit from `LemonSim.Bench.Ratings`.
  Team-mode games contribute one win per (winning-side model, losing-side
  model) pair, models deduplicated per side. Ranked-mode games compare
  per-model mean seat values pairwise. Records carry their mode, so
  recomputing standings never needs the adapter.
  """

  alias LemonSim.Bench.Artifacts.AtomicFile
  alias LemonSim.Bench.Ratings
  alias LemonSim.LLM.Projectors.Toolkit

  @schema "lemon_sim.league.v1"
  @game_schema "lemon_sim.league.v1.game"
  @recent_games_limit 25

  ## Match planning

  @doc """
  Plans a match: deterministically (for a given seed) picks one model spec per
  seat from `model_pool`.

  When the pool has at least `player_count` entries, models are sampled
  without replacement; smaller pools are cycled after a seeded shuffle. The
  returned `model_specs` list is positional: entry N goes to the Nth player id
  in sorted order (the convention shared by the mix tasks and `SimManager`).
  Applying the same seed before world construction also reproduces the
  scenario's own randomized role/seat assignment.
  """
  @spec plan_match([String.t()], keyword()) :: %{
          seed: pos_integer(),
          player_count: pos_integer(),
          model_specs: [String.t()]
        }
  def plan_match(model_pool, opts \\ []) when is_list(model_pool) and model_pool != [] do
    player_count = Keyword.get(opts, :player_count, 6)
    seed = Keyword.get(opts, :seed) || System.unique_integer([:positive])

    ordered =
      case Keyword.get(opts, :rotation_index) do
        index when is_integer(index) and index >= 0 ->
          rotate(model_pool, index)

        _ ->
          rand_state = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
          {shuffled, _rand_state} = seeded_shuffle(model_pool, rand_state)
          shuffled
      end

    model_specs =
      ordered
      |> Stream.cycle()
      |> Enum.take(player_count)

    %{
      seed: seed,
      player_count: player_count,
      model_specs: model_specs,
      rotation_index: Keyword.get(opts, :rotation_index)
    }
  end

  defp rotate([], _offset), do: []

  defp rotate(list, offset) do
    {left, right} = Enum.split(list, rem(offset, length(list)))
    right ++ left
  end

  defp seeded_shuffle(list, rand_state) do
    Enum.reduce(list, {[], rand_state}, fn item, {acc, state} ->
      {index, state} = :rand.uniform_s(length(acc) + 1, state)
      {List.insert_at(acc, index - 1, item), state}
    end)
  end

  ## Game records

  @doc """
  Builds a per-game league record from a finished world via `adapter`.

  `meta` supports: `:game_id` (required), `:recorded_at` (ISO8601 string,
  required so records stay reproducible), `:seed`, `:duration_ms`, `:turns`,
  and `:usage` (a `lemon_sim.usage.v1` artifact map or nil).
  """
  @spec game_record(module(), map(), keyword()) :: map()
  def game_record(adapter, world, meta) do
    game_id = Keyword.fetch!(meta, :game_id)
    recorded_at = Keyword.fetch!(meta, :recorded_at)
    summary = adapter.game_summary(world)
    {mode, direction} = normalize_mode(adapter.mode())

    seats =
      summary.seats
      |> Enum.into(%{}, fn {seat_id, seat} ->
        {to_string(seat_id),
         %{
           "model" => seat[:model],
           "role" => seat[:role],
           "won" => seat[:won] || false,
           "value" => seat[:value],
           "metrics" => stringify_metrics(seat[:metrics] || %{})
         }}
      end)

    %{
      "schema_version" => @game_schema,
      "scenario" => adapter.scenario_id(),
      "mode" => mode,
      "direction" => direction,
      "game_id" => game_id,
      "status" => Keyword.get(meta, :status, "completed"),
      "failure_reason" => Keyword.get(meta, :failure_reason),
      "failure_actor" => Keyword.get(meta, :failure_actor),
      "failure_model" => Keyword.get(meta, :failure_model),
      "recorded_at" => recorded_at,
      "seed" => Keyword.get(meta, :seed),
      "rotation_index" => Keyword.get(meta, :rotation_index),
      "winner" => summary.winner,
      "rounds" => summary.rounds,
      "seat_count" => map_size(seats),
      "seats" => seats,
      "turns" => Keyword.get(meta, :turns),
      "duration_ms" => Keyword.get(meta, :duration_ms),
      "usage" => Keyword.get(meta, :usage)
    }
  end

  defp normalize_mode(:team), do: {"team", nil}
  defp normalize_mode({:ranked, direction}), do: {"ranked", to_string(direction)}

  @doc """
  Persists a game record and recomputes the league standings. Pass
  `max_game_records: n` to keep a rolling league bounded to the newest `n`
  records.
  """
  @spec record_game!(String.t(), map()) :: {:ok, map()}
  def record_game!(league_dir, %{"game_id" => _game_id} = record) do
    record_game!(league_dir, record, [])
  end

  @spec record_game!(String.t(), map(), keyword()) :: {:ok, map()}
  def record_game!(league_dir, %{"game_id" => game_id} = record, opts) do
    path = Path.join([league_dir, "games", "#{sanitize_id(game_id)}.json"])
    AtomicFile.write!(path, Toolkit.stable_json(record) <> "\n")
    prune_game_records!(league_dir, Keyword.get(opts, :max_game_records))
    recompute!(league_dir)
  end

  defp prune_game_records!(_league_dir, nil), do: :ok

  defp prune_game_records!(league_dir, max_records)
       when is_integer(max_records) and max_records > 0 do
    games = load_games(league_dir)
    excess = max(length(games) - max_records, 0)

    games
    |> Enum.take(excess)
    |> Enum.each(fn game ->
      game_id = sanitize_id(game["game_id"])
      File.rm!(Path.join([league_dir, "games", "#{game_id}.json"]))
    end)
  end

  defp prune_game_records!(_league_dir, max_records) do
    raise ArgumentError,
          "max_game_records must be a positive integer, got: #{inspect(max_records)}"
  end

  @doc """
  Recomputes `league.json` and `league.md` from every game record on disk.
  """
  @spec recompute!(String.t()) :: {:ok, map()}
  def recompute!(league_dir) do
    games = load_games(league_dir)
    league = standings(games)

    AtomicFile.write!(Path.join(league_dir, "league.json"), Toolkit.stable_json(league) <> "\n")
    AtomicFile.write!(Path.join(league_dir, "league.md"), render_leaderboard(league))

    {:ok, league}
  end

  @doc """
  Loads all game records from a league directory, sorted by recorded_at then
  game_id for deterministic aggregation.
  """
  @spec load_games(String.t()) :: [map()]
  def load_games(league_dir) do
    league_dir
    |> Path.join("games/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      with {:ok, body} <- File.read(path),
           {:ok, %{"schema_version" => @game_schema} = game} <- Jason.decode(body) do
        [game]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(fn game -> {game["recorded_at"] || "", game["game_id"] || ""} end)
  end

  @doc """
  Reads the aggregated `league.json` from a league directory.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(league_dir) when is_binary(league_dir) do
    with {:ok, body} <- File.read(Path.join(league_dir, "league.json")),
         {:ok, %{"schema_version" => @schema} = league} <- Jason.decode(body) do
      {:ok, league}
    else
      {:ok, other} -> {:error, {:unsupported_schema, other["schema_version"]}}
      {:error, reason} -> {:error, reason}
    end
  end

  def load(_league_dir), do: {:error, :missing_league_dir}

  ## Standings

  @doc """
  Aggregates game records into league standings (pure).
  """
  @spec standings([map()]) :: map()
  def standings(games) when is_list(games) do
    completed_games = Enum.filter(games, &completed_game?/1)
    model_ids = collect_model_ids(games)
    matrix = pairwise_matrix(completed_games, model_ids)
    ratings = Ratings.fit_ratings(model_ids, matrix)
    role_baselines = role_win_baselines(completed_games)
    role_coverage_complete? = role_coverage_complete?(completed_games, model_ids)

    models =
      model_ids
      |> Enum.map(fn model ->
        model_row(model, completed_games, games, ratings[model], role_baselines)
      end)
      |> Enum.sort_by(fn row ->
        case row["rating"] do
          nil -> {1, 0.0, row["model"]}
          rating -> {0, -rating, row["model"]}
        end
      end)

    first = List.first(games) || %{}

    %{
      "schema_version" => @schema,
      "scenario" => first["scenario"],
      "mode" => first["mode"],
      "as_of" => games |> Enum.map(& &1["recorded_at"]) |> Enum.max(fn -> nil end),
      "game_count" => length(completed_games),
      "attempt_count" => length(games),
      "failed_attempt_count" => Enum.count(games, &(not completed_game?(&1))),
      "algorithm" => %{
        "name" => "bradley_terry_mle_fixed_point",
        "team_pairing" => "one win per (winning-side model, losing-side model) pair per game",
        "ranked_pairing" => "per-model mean seat value compared pairwise per game",
        "rating_base" => 1500,
        "rating_scale" => 400
      },
      "rating_status" =>
        if(role_coverage_complete?, do: "role_coverage_complete", else: "provisional"),
      "role_win_baselines" => role_baselines,
      "models" => models,
      "recent_games" => recent_games(completed_games),
      "recent_failed_attempts" => recent_failed_attempts(games)
    }
  end

  defp collect_model_ids(games) do
    games
    |> Enum.flat_map(fn game ->
      game["seats"] |> Map.values() |> Enum.map(&seat_model/1)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp seat_model(seat), do: seat["model"] || "unknown"

  defp pairwise_matrix(games, model_ids) do
    base = Ratings.new_pairwise_matrix(model_ids)
    Enum.reduce(games, base, &add_game_outcomes/2)
  end

  defp add_game_outcomes(%{"mode" => "team"} = game, matrix) do
    {won, lost} =
      game["seats"]
      |> Map.values()
      |> Enum.split_with(& &1["won"])

    winners = won |> Enum.map(&seat_model/1) |> Enum.uniq() |> Enum.sort()
    losers = lost |> Enum.map(&seat_model/1) |> Enum.uniq() |> Enum.sort()

    for w <- winners, l <- losers, reduce: matrix do
      acc -> Ratings.add_pairwise_win(acc, w, l)
    end
  end

  defp add_game_outcomes(%{"mode" => "ranked"} = game, matrix) do
    direction = if game["direction"] == "minimize", do: :minimize, else: :maximize

    means =
      game["seats"]
      |> Map.values()
      |> Enum.filter(&is_number(&1["value"]))
      |> Enum.group_by(&seat_model/1, & &1["value"])
      |> Enum.map(fn {model, values} -> {model, Enum.sum(values) / length(values)} end)
      |> Enum.sort()

    for {left, lv} <- means, {right, rv} <- means, left < right, lv != rv, reduce: matrix do
      acc ->
        winner? =
          case direction do
            :maximize -> lv > rv
            :minimize -> lv < rv
          end

        if winner? do
          Ratings.add_pairwise_win(acc, left, right)
        else
          Ratings.add_pairwise_win(acc, right, left)
        end
    end
  end

  defp add_game_outcomes(_game, matrix), do: matrix

  defp model_row(model, games, attempts, rating, role_baselines) do
    seats =
      Enum.flat_map(games, fn game ->
        game["seats"]
        |> Map.values()
        |> Enum.filter(&(seat_model(&1) == model))
        |> Enum.map(&Map.put(&1, "game_id", game["game_id"]))
      end)

    wins = Enum.count(seats, & &1["won"])
    values = seats |> Enum.map(& &1["value"]) |> Enum.filter(&is_number/1)

    roles =
      seats
      |> Enum.filter(& &1["role"])
      |> Enum.group_by(& &1["role"])
      |> Enum.into(%{}, fn {role, role_seats} -> {role, seat_stats(role_seats)} end)

    attempted_game_ids =
      attempts
      |> Enum.filter(fn game ->
        Enum.any?(Map.values(game["seats"] || %{}), &(seat_model(&1) == model))
      end)
      |> Enum.map(& &1["game_id"])
      |> Enum.uniq()

    failed_attempts =
      attempts
      |> Enum.reject(&completed_game?/1)
      |> Enum.count(&(&1["failure_model"] == model))

    %{
      "model" => model,
      "rating" => rating,
      "games" => seats |> Enum.map(& &1["game_id"]) |> Enum.uniq() |> length(),
      "attempts" => length(attempted_game_ids),
      "failed_attempts" => failed_attempts,
      "completion_rate" =>
        ratio(length(attempted_game_ids) - failed_attempts, length(attempted_game_ids)),
      "seats" => length(seats),
      "wins" => wins,
      "win_rate" => ratio(wins, length(seats)),
      "role_adjusted_win_rate" => role_adjusted_win_rate(seats, role_baselines),
      "value_mean" => mean(values),
      "metrics" => sum_metrics(seats),
      "roles" => roles
    }
  end

  defp role_win_baselines(games) do
    games
    |> Enum.flat_map(fn game -> Map.values(game["seats"] || %{}) end)
    |> Enum.filter(&is_binary(&1["role"]))
    |> Enum.group_by(& &1["role"])
    |> Enum.into(%{}, fn {role, seats} ->
      {role, ratio(Enum.count(seats, & &1["won"]), length(seats))}
    end)
  end

  defp role_adjusted_win_rate([], _baselines), do: nil

  defp role_adjusted_win_rate(seats, baselines) do
    adjusted =
      Enum.map(seats, fn seat ->
        outcome = if seat["won"], do: 1.0, else: 0.0
        baseline = Map.get(baselines, seat["role"], 0.5)
        min(1.0, max(0.0, 0.5 + outcome - baseline))
      end)

    mean(adjusted)
  end

  defp role_coverage_complete?([], _model_ids), do: false

  defp role_coverage_complete?(games, model_ids) do
    seats = Enum.flat_map(games, fn game -> Map.values(game["seats"] || %{}) end)

    required_roles =
      seats
      |> Enum.map(& &1["role"])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    MapSet.size(required_roles) == 0 or
      Enum.all?(model_ids, fn model ->
        covered =
          seats
          |> Enum.filter(&(seat_model(&1) == model))
          |> Enum.map(& &1["role"])
          |> MapSet.new()

        MapSet.subset?(required_roles, covered)
      end)
  end

  defp seat_stats(seats) do
    wins = Enum.count(seats, & &1["won"])

    %{
      "seats" => length(seats),
      "wins" => wins,
      "win_rate" => ratio(wins, length(seats)),
      "metrics" => sum_metrics(seats)
    }
  end

  defp sum_metrics(seats) do
    seats
    |> Enum.flat_map(fn seat -> Map.to_list(seat["metrics"] || %{}) end)
    |> Enum.filter(fn {_key, value} -> is_number(value) end)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.update(acc, key, value, &(&1 + value))
    end)
  end

  defp recent_games(games) do
    games
    |> Enum.sort_by(fn game -> {game["recorded_at"] || "", game["game_id"] || ""} end, :desc)
    |> Enum.take(@recent_games_limit)
    |> Enum.map(fn game ->
      %{
        "game_id" => game["game_id"],
        "recorded_at" => game["recorded_at"],
        "winner" => game["winner"],
        "rounds" => game["rounds"],
        "seat_count" => game["seat_count"],
        "duration_ms" => game["duration_ms"],
        "winning_models" =>
          game["seats"]
          |> Map.values()
          |> Enum.filter(& &1["won"])
          |> Enum.map(&seat_model/1)
          |> Enum.uniq()
          |> Enum.sort(),
        "roles" => roles_to_models(game)
      }
    end)
  end

  defp recent_failed_attempts(games) do
    games
    |> Enum.reject(&completed_game?/1)
    |> Enum.sort_by(fn game -> {game["recorded_at"] || "", game["game_id"] || ""} end, :desc)
    |> Enum.take(@recent_games_limit)
    |> Enum.map(
      &Map.take(&1, [
        "game_id",
        "recorded_at",
        "failure_reason",
        "failure_actor",
        "failure_model",
        "duration_ms",
        "rotation_index"
      ])
    )
  end

  defp completed_game?(game), do: game["status"] in [nil, "completed"]

  defp roles_to_models(game) do
    game["seats"]
    |> Map.values()
    |> Enum.filter(& &1["role"])
    |> Enum.group_by(& &1["role"])
    |> Enum.into(%{}, fn {role, seats} ->
      {role, seats |> Enum.map(&seat_model/1) |> Enum.sort()}
    end)
  end

  defp mean([]), do: nil
  defp mean(values), do: Float.round(Enum.sum(values) / length(values), 4)

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: Float.round(numerator / denominator, 4)

  ## Rendering

  @doc """
  Renders the league standings as a markdown leaderboard.
  """
  @spec render_leaderboard(map()) :: String.t()
  def render_leaderboard(league) do
    ranked? = league["mode"] == "ranked"

    value_header = if ranked?, do: " Mean value |", else: ""

    header = [
      "# #{league["scenario"] || "League"} Leaderboard",
      "",
      "Games: #{league["game_count"]} completed / #{league["attempt_count"] || league["game_count"]} attempts",
      "Ratings: Bradley-Terry MLE (1500-centered, #{league["rating_status"] || "provisional"}).",
      "",
      "| Rank | Model | Rating | Games | Completion | Seats | Wins | Win rate | Role-adjusted |#{value_header}",
      "|---:|---|---:|---:|---:|---:|---:|---:|---:|#{if ranked?, do: "---:|", else: ""}"
    ]

    rows =
      league
      |> Map.get("models", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {row, index} ->
        rank = if row["rating"], do: index, else: "-"

        cells = [
          rank,
          row["model"],
          format_rating(row["rating"]),
          row["games"],
          format_percent(row["completion_rate"]),
          row["seats"],
          row["wins"],
          format_percent(row["win_rate"]),
          format_percent(row["role_adjusted_win_rate"])
        ]

        cells = if ranked?, do: cells ++ [format_value(row["value_mean"])], else: cells
        "| #{Enum.join(cells, " | ")} |"
      end)

    (header ++ rows ++ [""]) |> Enum.join("\n")
  end

  defp format_rating(nil), do: "unrated"
  defp format_rating(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp format_percent(nil), do: "-"
  defp format_percent(value), do: "#{:erlang.float_to_binary(value * 100.0, decimals: 1)}%"

  defp format_value(nil), do: "-"
  defp format_value(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp sanitize_id(game_id) do
    game_id |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
  end

  defp stringify_metrics(metrics) when is_map(metrics) do
    metrics
    |> Enum.filter(fn {_key, value} -> is_number(value) end)
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end
end
