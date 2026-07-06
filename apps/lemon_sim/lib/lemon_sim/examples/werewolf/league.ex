defmodule LemonSim.Examples.Werewolf.League do
  @moduledoc """
  Persistent multi-game Werewolf league: match planning, per-game records,
  and per-model / per-role standings with Bradley-Terry ratings.

  The league is file-backed and deterministic. A league directory contains:

    * `games/<game_id>.json` — one record per finished game (schema
      `lemon_sim.werewolf_league.v1.game`), derived from the final world via
      `LemonSim.Examples.Werewolf.Performance`.
    * `league.json` — aggregated standings recomputed from every game record
      (schema `lemon_sim.werewolf_league.v1`). Byte-deterministic for a given
      set of game records.
    * `league.md` — human-readable leaderboard rendered from the same data.

  Ratings use the shared Bradley-Terry fit from `LemonSim.Bench.Ratings`:
  every game contributes one win per (winning-team model, losing-team model)
  pair, models deduplicated per team. Roles are tracked per seat, so a model's
  record as werewolf, seer, doctor, and villager accumulate independently.
  """

  import LemonSim.Examples.Helpers

  alias LemonSim.Bench.Artifacts.AtomicFile
  alias LemonSim.Bench.Ratings
  alias LemonSim.Examples.Werewolf.Performance
  alias LemonSim.LLM.Projectors.Toolkit

  @schema "lemon_sim.werewolf_league.v1"
  @game_schema "lemon_sim.werewolf_league.v1.game"
  @recent_games_limit 25

  @role_counters ~w(votes_for_werewolf votes_for_villager skip_votes partner_votes
                    night_actions_used successful_kills failed_kills
                    wolf_checks_found doctor_saves)

  ## Match planning

  @doc """
  Plans a match: deterministically (for a given seed) picks one model spec per
  seat from `model_pool`.

  When the pool has at least `player_count` entries, models are sampled
  without replacement; smaller pools are cycled after a seeded shuffle, so
  duplicate seats are spread as evenly as possible. The returned
  `model_specs` list is positional: entry N is assigned to the Nth player id
  in sorted order (the convention used by the werewolf mix task and
  `SimManager`). Role assignment itself is randomized by the engine when the
  same seed is applied before world construction, so the model-to-role pairing
  is random but reproducible.
  """
  @spec plan_match([String.t()], keyword()) :: %{
          seed: pos_integer(),
          player_count: pos_integer(),
          model_specs: [String.t()]
        }
  def plan_match(model_pool, opts \\ []) when is_list(model_pool) and model_pool != [] do
    player_count = Keyword.get(opts, :player_count, 6)
    seed = Keyword.get(opts, :seed) || System.unique_integer([:positive])

    rand_state = :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
    {shuffled, _rand_state} = seeded_shuffle(model_pool, rand_state)

    model_specs =
      shuffled
      |> Stream.cycle()
      |> Enum.take(player_count)

    %{seed: seed, player_count: player_count, model_specs: model_specs}
  end

  defp seeded_shuffle(list, rand_state) do
    Enum.reduce(list, {[], rand_state}, fn item, {acc, state} ->
      {index, state} = :rand.uniform_s(length(acc) + 1, state)
      {List.insert_at(acc, index - 1, item), state}
    end)
  end

  ## Game records

  @doc """
  Builds a per-game league record from a finished world.

  `meta` supports: `:game_id` (required), `:recorded_at` (ISO8601 string,
  required so records stay reproducible), `:seed`, `:duration_ms`, `:turns`,
  and `:usage` (a `lemon_sim.usage.v1` artifact map or nil).
  """
  @spec game_record(map(), keyword()) :: map()
  def game_record(world, meta) do
    game_id = Keyword.fetch!(meta, :game_id)
    recorded_at = Keyword.fetch!(meta, :recorded_at)
    performance = Performance.summarize(world)

    players =
      performance
      |> Map.fetch!(:players)
      |> Enum.into(%{}, fn {player_id, metrics} ->
        {to_string(player_id), stringify_keys(metrics)}
      end)

    %{
      "schema_version" => @game_schema,
      "game_id" => game_id,
      "recorded_at" => recorded_at,
      "seed" => Keyword.get(meta, :seed),
      "winner" => get(world, :winner),
      "day_count" => get(world, :day_number, 0),
      "player_count" => map_size(players),
      "turns" => Keyword.get(meta, :turns),
      "duration_ms" => Keyword.get(meta, :duration_ms),
      "players" => players,
      "usage" => Keyword.get(meta, :usage)
    }
  end

  @doc """
  Persists a game record and recomputes the league standings.

  Returns `{:ok, league}` with the freshly written standings map.
  """
  @spec record_game!(String.t(), map()) :: {:ok, map()}
  def record_game!(league_dir, %{"game_id" => game_id} = record) do
    path = Path.join([league_dir, "games", "#{sanitize_id(game_id)}.json"])
    AtomicFile.write!(path, Toolkit.stable_json(record) <> "\n")
    recompute!(league_dir)
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
    model_ids = collect_model_ids(games)
    matrix = pairwise_matrix(games, model_ids)
    ratings = Ratings.fit_ratings(model_ids, matrix)

    models =
      model_ids
      |> Enum.map(fn model -> model_row(model, games, ratings[model]) end)
      |> Enum.sort_by(fn row ->
        case row["rating"] do
          nil -> {1, 0.0, row["model"]}
          rating -> {0, -rating, row["model"]}
        end
      end)

    %{
      "schema_version" => @schema,
      "as_of" => games |> Enum.map(& &1["recorded_at"]) |> Enum.max(fn -> nil end),
      "game_count" => length(games),
      "algorithm" => %{
        "name" => "bradley_terry_mle_fixed_point",
        "pairing" => "one win per (winning-team model, losing-team model) pair per game",
        "rating_base" => 1500,
        "rating_scale" => 400
      },
      "models" => models,
      "recent_games" => recent_games(games)
    }
  end

  defp collect_model_ids(games) do
    games
    |> Enum.flat_map(fn game ->
      game["players"] |> Map.values() |> Enum.map(&(&1["model"] || "unknown"))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp pairwise_matrix(games, model_ids) do
    base = Ratings.new_pairwise_matrix(model_ids)

    Enum.reduce(games, base, fn game, matrix ->
      case game["winner"] do
        winner when winner in ["werewolves", "villagers"] ->
          {winners, losers} = team_models(game, winner)

          for w <- winners, l <- losers, reduce: matrix do
            acc -> Ratings.add_pairwise_win(acc, w, l)
          end

        _ ->
          matrix
      end
    end)
  end

  defp team_models(game, winner) do
    game["players"]
    |> Map.values()
    |> Enum.split_with(&(&1["team"] == winner))
    |> then(fn {winning, losing} ->
      {team_model_ids(winning), team_model_ids(losing)}
    end)
  end

  defp team_model_ids(seats) do
    seats |> Enum.map(&(&1["model"] || "unknown")) |> Enum.uniq() |> Enum.sort()
  end

  defp model_row(model, games, rating) do
    seats =
      Enum.flat_map(games, fn game ->
        game["players"]
        |> Map.values()
        |> Enum.filter(&((&1["model"] || "unknown") == model))
        |> Enum.map(&Map.put(&1, "game_id", game["game_id"]))
      end)

    seat_wins = Enum.count(seats, & &1["team_won"])

    roles =
      seats
      |> Enum.group_by(&(&1["role"] || "unknown"))
      |> Enum.into(%{}, fn {role, role_seats} ->
        {role, role_stats(role_seats)}
      end)

    %{
      "model" => model,
      "rating" => rating,
      "games" => seats |> Enum.map(& &1["game_id"]) |> Enum.uniq() |> length(),
      "seats" => length(seats),
      "wins" => seat_wins,
      "win_rate" => ratio(seat_wins, length(seats)),
      "survival_rate" => ratio(Enum.count(seats, & &1["survived"]), length(seats)),
      "roles" => roles
    }
  end

  defp role_stats(role_seats) do
    wins = Enum.count(role_seats, & &1["team_won"])

    counters =
      Enum.into(@role_counters, %{}, fn counter ->
        {counter, role_seats |> Enum.map(&(&1[counter] || 0)) |> Enum.sum()}
      end)

    Map.merge(counters, %{
      "seats" => length(role_seats),
      "wins" => wins,
      "win_rate" => ratio(wins, length(role_seats)),
      "survived" => Enum.count(role_seats, & &1["survived"])
    })
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
        "day_count" => game["day_count"],
        "player_count" => game["player_count"],
        "duration_ms" => game["duration_ms"],
        "roles" => roles_to_models(game)
      }
    end)
  end

  defp roles_to_models(game) do
    game["players"]
    |> Map.values()
    |> Enum.group_by(&(&1["role"] || "unknown"))
    |> Enum.into(%{}, fn {role, seats} ->
      {role, seats |> Enum.map(&(&1["model"] || "unknown")) |> Enum.sort()}
    end)
  end

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: Float.round(numerator / denominator, 4)

  ## Rendering

  @doc """
  Renders the league standings as a markdown leaderboard.
  """
  @spec render_leaderboard(map()) :: String.t()
  def render_leaderboard(league) do
    header = [
      "# Werewolf League Leaderboard",
      "",
      "Games: #{league["game_count"]}",
      "Ratings: Bradley-Terry MLE over team outcomes (1500-centered).",
      "",
      "| Rank | Model | Rating | Games | Seats | Wins | Win rate | Survival |",
      "|---:|---|---:|---:|---:|---:|---:|---:|"
    ]

    rows =
      league
      |> Map.get("models", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {row, index} ->
        rank = if row["rating"], do: index, else: "-"

        [
          rank,
          row["model"],
          format_rating(row["rating"]),
          row["games"],
          row["seats"],
          row["wins"],
          format_percent(row["win_rate"]),
          format_percent(row["survival_rate"])
        ]
        |> then(fn cells -> "| #{Enum.join(cells, " | ")} |" end)
      end)

    (header ++ rows ++ [""]) |> Enum.join("\n")
  end

  defp format_rating(nil), do: "unrated"
  defp format_rating(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp format_percent(nil), do: "-"
  defp format_percent(value), do: "#{:erlang.float_to_binary(value * 100.0, decimals: 1)}%"

  defp sanitize_id(game_id) do
    game_id |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), value} end)
  end
end
