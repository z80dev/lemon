defmodule LemonSim.Examples.WerewolfLeagueTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.League

  @moduletag :tmp_dir

  describe "plan_match/2" do
    test "is deterministic for a given seed" do
      pool = ["a:m1", "b:m2", "c:m3", "d:m4", "e:m5", "f:m6", "g:m7"]

      plan1 = League.plan_match(pool, player_count: 6, seed: 42)
      plan2 = League.plan_match(pool, player_count: 6, seed: 42)

      assert plan1 == plan2
      assert plan1.seed == 42
      assert length(plan1.model_specs) == 6
      # Sampling without replacement when the pool is large enough.
      assert plan1.model_specs == Enum.uniq(plan1.model_specs)
      assert Enum.all?(plan1.model_specs, &(&1 in pool))
    end

    test "different seeds produce different assignments" do
      pool = Enum.map(1..8, &"p:m#{&1}")

      plans =
        Enum.map(1..20, fn seed ->
          League.plan_match(pool, player_count: 8, seed: seed).model_specs
        end)

      assert plans |> Enum.uniq() |> length() > 1
    end

    test "cycles a small pool to fill all seats" do
      plan = League.plan_match(["a:m1", "b:m2"], player_count: 6, seed: 7)

      assert length(plan.model_specs) == 6
      counts = Enum.frequencies(plan.model_specs)
      assert counts["a:m1"] == 3
      assert counts["b:m2"] == 3
    end

    test "generates a seed when none is given" do
      plan = League.plan_match(["a:m1"], player_count: 5)
      assert is_integer(plan.seed) and plan.seed > 0
    end
  end

  describe "game_record/2" do
    test "captures winner, players, and meta from a final world" do
      record =
        League.game_record(finished_world(),
          game_id: "ww_test1",
          recorded_at: "2026-07-06T00:00:00Z",
          seed: 42,
          duration_ms: 60_000,
          turns: 30,
          usage: %{"totals" => %{"input_tokens" => 10}}
        )

      assert record["schema_version"] == "lemon_sim.werewolf_league.v1.game"
      assert record["game_id"] == "ww_test1"
      assert record["winner"] == "villagers"
      assert record["player_count"] == 4
      assert record["players"]["Aria"]["role"] == "werewolf"
      assert record["players"]["Aria"]["team"] == "werewolves"
      refute record["players"]["Aria"]["team_won"]
      assert record["players"]["Brin"]["team_won"]
      assert record["players"]["Brin"]["model"] == "anthropic/claude-x"
      assert record["usage"]["totals"]["input_tokens"] == 10
    end
  end

  describe "record_game!/2 and standings" do
    test "writes game record, league.json, and league.md", %{tmp_dir: dir} do
      record =
        League.game_record(finished_world(),
          game_id: "ww_test1",
          recorded_at: "2026-07-06T00:00:00Z",
          seed: 1
        )

      {:ok, league} = League.record_game!(dir, record)

      assert File.regular?(Path.join(dir, "games/ww_test1.json"))
      assert File.regular?(Path.join(dir, "league.json"))
      assert File.regular?(Path.join(dir, "league.md"))

      assert league["game_count"] == 1
      assert {:ok, loaded} = League.load(dir)
      assert loaded == league
    end

    test "standings aggregate per model and per role", %{tmp_dir: dir} do
      for {game_id, winner} <- [{"g1", "villagers"}, {"g2", "werewolves"}] do
        record =
          League.game_record(finished_world(winner: winner),
            game_id: game_id,
            recorded_at: "2026-07-06T00:00:0#{if game_id == "g1", do: 0, else: 1}Z"
          )

        {:ok, _} = League.record_game!(dir, record)
      end

      {:ok, league} = League.load(dir)
      assert league["game_count"] == 2

      wolf_model = Enum.find(league["models"], &(&1["model"] == "openai/gpt-x"))
      assert wolf_model["seats"] == 2
      assert wolf_model["wins"] == 1
      assert wolf_model["win_rate"] == 0.5
      assert wolf_model["roles"]["werewolf"]["seats"] == 2
      assert wolf_model["roles"]["werewolf"]["wins"] == 1

      village_model = Enum.find(league["models"], &(&1["model"] == "anthropic/claude-x"))
      assert village_model["roles"]["seer"]["seats"] == 2
      assert village_model["roles"]["seer"]["wolf_checks_found"] == 2
    end

    test "ratings favor the model that keeps winning", %{tmp_dir: dir} do
      for index <- 1..6 do
        record =
          League.game_record(finished_world(winner: "villagers"),
            game_id: "g#{index}",
            recorded_at: "2026-07-06T00:00:0#{index}Z"
          )

        {:ok, _} = League.record_game!(dir, record)
      end

      {:ok, league} = League.load(dir)
      [top | _] = league["models"]

      # Villager-side models win every game, so they must outrank the wolf model.
      assert top["model"] in ["anthropic/claude-x", "google/gemini-x"]
      wolf = Enum.find(league["models"], &(&1["model"] == "openai/gpt-x"))
      assert wolf["rating"] < top["rating"]
    end

    test "recompute is byte-deterministic", %{tmp_dir: dir} do
      record =
        League.game_record(finished_world(),
          game_id: "g1",
          recorded_at: "2026-07-06T00:00:00Z"
        )

      {:ok, _} = League.record_game!(dir, record)
      first = File.read!(Path.join(dir, "league.json"))
      {:ok, _} = League.recompute!(dir)
      assert File.read!(Path.join(dir, "league.json")) == first
    end
  end

  # A minimal finished world exercising roles, votes, and night history.
  defp finished_world(opts \\ []) do
    winner = Keyword.get(opts, :winner, "villagers")

    %{
      status: "game_over",
      winner: winner,
      day_number: 3,
      players: %{
        "Aria" => %{role: "werewolf", model: "openai/gpt-x", status: "dead"},
        "Brin" => %{role: "seer", model: "anthropic/claude-x", status: "alive"},
        "Cole" => %{role: "doctor", model: "google/gemini-x", status: "alive"},
        "Dara" => %{role: "villager", model: "anthropic/claude-x", status: "alive"}
      },
      vote_history: [
        %{voter: "Brin", target: "Aria", voter_role: "seer", target_role: "werewolf"},
        %{voter: "Dara", target: "skip", voter_role: "villager", target_role: nil}
      ],
      night_history: [
        %{player: "Aria", action: "choose_victim", successful: false},
        %{player: "Brin", action: "investigate", result: "werewolf"},
        %{player: "Cole", action: "protect", saved: true}
      ]
    }
  end
end
