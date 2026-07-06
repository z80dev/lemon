defmodule LemonSim.Bench.LeagueTest do
  use ExUnit.Case, async: true

  alias LemonSim.Bench.League
  alias LemonSim.Bench.League.Registry
  alias LemonSim.Examples.Poker
  alias LemonSim.Examples.SpaceStation
  alias LemonSim.Examples.StockMarket
  alias LemonSim.Examples.Survivor
  alias LemonSim.Examples.Werewolf

  @moduletag :tmp_dir

  describe "plan_match/2" do
    test "is deterministic for a given seed and samples without replacement" do
      pool = ["a:m1", "b:m2", "c:m3", "d:m4", "e:m5", "f:m6", "g:m7"]

      plan1 = League.plan_match(pool, player_count: 6, seed: 42)
      plan2 = League.plan_match(pool, player_count: 6, seed: 42)

      assert plan1 == plan2
      assert length(plan1.model_specs) == 6
      assert plan1.model_specs == Enum.uniq(plan1.model_specs)
      assert Enum.all?(plan1.model_specs, &(&1 in pool))
    end

    test "cycles a small pool to fill all seats" do
      plan = League.plan_match(["a:m1", "b:m2"], player_count: 6, seed: 7)

      counts = Enum.frequencies(plan.model_specs)
      assert counts["a:m1"] == 3
      assert counts["b:m2"] == 3
    end

    test "different seeds vary assignments and a missing seed is generated" do
      pool = Enum.map(1..8, &"p:m#{&1}")

      plans =
        Enum.map(1..20, fn seed ->
          League.plan_match(pool, player_count: 8, seed: seed).model_specs
        end)

      assert plans |> Enum.uniq() |> length() > 1
      assert League.plan_match(pool, player_count: 5).seed > 0
    end
  end

  describe "registry" do
    test "registers the five arena scenarios" do
      assert Registry.scenario_ids() == [
               "poker",
               "space_station",
               "stock_market",
               "survivor",
               "werewolf"
             ]

      assert {:ok, Werewolf.League} = Registry.fetch(:werewolf)
      assert Registry.get("nope") == nil
    end
  end

  describe "team mode (werewolf adapter)" do
    test "records per-role seats and rates winners above losers", %{tmp_dir: dir} do
      for index <- 1..4 do
        record =
          League.game_record(Werewolf.League, werewolf_world(),
            game_id: "g#{index}",
            recorded_at: "2026-07-06T00:00:0#{index}Z",
            seed: index
          )

        {:ok, _} = League.record_game!(dir, record)
      end

      {:ok, league} = League.load(dir)

      assert league["scenario"] == "werewolf"
      assert league["mode"] == "team"
      assert league["game_count"] == 4

      [top | _] = league["models"]
      assert top["model"] in ["anthropic/claude-x", "google/gemini-x"]

      wolf = Enum.find(league["models"], &(&1["model"] == "openai/gpt-x"))
      assert wolf["rating"] < top["rating"]
      assert wolf["roles"]["werewolf"]["seats"] == 4
      assert wolf["roles"]["werewolf"]["metrics"]["failed_kills"] == 4

      seer = Enum.find(league["models"], &(&1["model"] == "anthropic/claude-x"))
      assert seer["roles"]["seer"]["metrics"]["wolf_checks_found"] == 4
    end
  end

  describe "team mode winner-take-all (survivor adapter)" do
    test "sole survivor's model beats the field", %{tmp_dir: dir} do
      record =
        League.game_record(Survivor.League, survivor_world(),
          game_id: "s1",
          recorded_at: "2026-07-06T00:00:00Z"
        )

      {:ok, league} = League.record_game!(dir, record)

      assert record["winner"] == "Kai"
      kai_seat = record["seats"]["Kai"]
      assert kai_seat["won"]
      assert kai_seat["model"] == "zai/glm-5"
      assert kai_seat["metrics"]["jury_votes_received"] == 2

      [top | _] = league["models"]
      assert top["model"] == "zai/glm-5"
      assert top["wins"] == 1
    end
  end

  describe "ranked mode (stock market adapter)" do
    test "pairwise ratings follow portfolio values", %{tmp_dir: dir} do
      record =
        League.game_record(StockMarket.League, stock_market_world(),
          game_id: "m1",
          recorded_at: "2026-07-06T00:00:00Z"
        )

      {:ok, league} = League.record_game!(dir, record)

      assert record["mode"] == "ranked"
      assert record["direction"] == "maximize"
      assert league["mode"] == "ranked"

      [top | _rest] = league["models"]
      assert top["model"] == "anthropic/claude-x"
      assert top["value_mean"] > 0

      bottom = List.last(league["models"])
      assert bottom["model"] == "openai/gpt-x"
      assert bottom["rating"] < top["rating"]
    end
  end

  describe "ranked mode (poker adapter)" do
    test "pairwise ratings follow final chip stacks", %{tmp_dir: dir} do
      record =
        League.game_record(Poker.League, poker_world(),
          game_id: "p1",
          recorded_at: "2026-07-06T00:00:00Z"
        )

      {:ok, league} = League.record_game!(dir, record)

      assert record["mode"] == "ranked"
      assert record["direction"] == "maximize"
      assert record["winner"] == "player_1"
      assert record["rounds"] == 12

      winner_seat = record["seats"]["player_1"]
      assert winner_seat["won"]
      assert winner_seat["model"] == "anthropic/claude-x"
      assert winner_seat["value"] == 4200
      assert winner_seat["metrics"]["profit_loss"] == 2200
      assert winner_seat["metrics"]["hands_won"] == 6

      [top | _rest] = league["models"]
      assert top["model"] == "anthropic/claude-x"

      bottom = List.last(league["models"])
      assert bottom["model"] == "openai/gpt-x"
      assert bottom["rating"] < top["rating"]
    end
  end

  describe "space station adapter" do
    test "handles list-shaped scorecard players and team split" do
      record =
        League.game_record(SpaceStation.League, space_station_world(),
          game_id: "sp1",
          recorded_at: "2026-07-06T00:00:00Z"
        )

      assert record["winner"] == "crew"
      saboteur = record["seats"]["player_1"]
      refute saboteur["won"]
      assert saboteur["role"] == "saboteur"
      assert saboteur["metrics"]["fake_repairs"] == 2

      crew = record["seats"]["player_2"]
      assert crew["won"]
      assert crew["metrics"]["correct_votes"] == 1
    end
  end

  describe "persistence" do
    test "recompute is byte-deterministic and load round-trips", %{tmp_dir: dir} do
      record =
        League.game_record(Werewolf.League, werewolf_world(),
          game_id: "g1",
          recorded_at: "2026-07-06T00:00:00Z"
        )

      {:ok, league} = League.record_game!(dir, record)
      first = File.read!(Path.join(dir, "league.json"))
      {:ok, _} = League.recompute!(dir)

      assert File.read!(Path.join(dir, "league.json")) == first
      assert {:ok, ^league} = League.load(dir)
      assert File.regular?(Path.join(dir, "league.md"))
    end
  end

  ## Fixture worlds (minimal finished worlds per scenario)

  defp werewolf_world do
    %{
      status: "game_over",
      winner: "villagers",
      day_number: 3,
      players: %{
        "Aria" => %{role: "werewolf", model: "openai/gpt-x", status: "dead"},
        "Brin" => %{role: "seer", model: "anthropic/claude-x", status: "alive"},
        "Cole" => %{role: "doctor", model: "google/gemini-x", status: "alive"},
        "Dara" => %{role: "villager", model: "anthropic/claude-x", status: "alive"}
      },
      vote_history: [
        %{voter: "Brin", target: "Aria", voter_role: "seer", target_role: "werewolf"}
      ],
      night_history: [
        %{player: "Aria", action: "choose_victim", successful: false},
        %{player: "Brin", action: "investigate", result: "werewolf"}
      ]
    }
  end

  defp survivor_world do
    %{
      status: "game_over",
      winner: "Kai",
      players: %{
        "Kai" => %{model: "zai/glm-5", status: "alive"},
        "Sierra" => %{model: "openai/gpt-x", status: "alive"},
        "Talon" => %{model: "anthropic/claude-x", status: "eliminated"}
      },
      challenge_history: [],
      whisper_history: [%{from: "Kai", to: "Sierra"}],
      vote_history: [],
      idol_history: [],
      jury_votes: %{"Talon" => "Kai", "Marlow" => "Kai"},
      elimination_log: [%{player: "Talon"}]
    }
  end

  defp stock_market_world do
    %{
      status: "game_over",
      winner: "player_1",
      round: 10,
      players: %{
        "player_1" => %{name: "Ava", model: "anthropic/claude-x", cash: 2000, holdings: %{}},
        "player_2" => %{name: "Bo", model: "zai/glm-5", cash: 1200, holdings: %{}},
        "player_3" => %{name: "Cy", model: "openai/gpt-x", cash: 800, holdings: %{}}
      },
      stocks: %{},
      market_call_history: [],
      round_summaries: [],
      whisper_history: []
    }
  end

  defp poker_world do
    %{
      status: "game_over",
      winner: "player_1",
      winner_ids: ["player_1"],
      completed_hands: 12,
      table: %{big_blind: 100, small_blind: 50},
      players: %{
        "player_1" => %{seat: 1, model: "anthropic/claude-x"},
        "player_2" => %{seat: 2, model: "zai/glm-5"},
        "player_3" => %{seat: 3, model: "openai/gpt-x"}
      },
      chip_counts: [
        %{"seat" => 1, "player_id" => "player_1", "stack" => 4200, "status" => "active"},
        %{"seat" => 2, "player_id" => "player_2", "stack" => 1500, "status" => "active"},
        %{"seat" => 3, "player_id" => "player_3", "stack" => 300, "status" => "active"}
      ],
      player_stats: %{
        "player_1" => poker_stats(hands_won: 6, vpip_hands: 8, pfr_hands: 5),
        "player_2" => poker_stats(hands_won: 4, vpip_hands: 6, pfr_hands: 3),
        "player_3" => poker_stats(hands_won: 2, vpip_hands: 10, pfr_hands: 1)
      }
    }
  end

  defp poker_stats(overrides) do
    Enum.into(overrides, %{
      starting_stack: 2000,
      hands_played: 12,
      hands_won: 0,
      vpip_hands: 0,
      pfr_hands: 0,
      total_actions: 30,
      fold_count: 5,
      check_count: 5,
      call_count: 8,
      bet_count: 6,
      raise_count: 6
    })
  end

  defp space_station_world do
    %{
      status: "game_over",
      winner: "crew",
      round: 5,
      players: %{
        "player_1" => %{name: "Nova", role: "saboteur", model: "openai/gpt-x", status: "ejected"},
        "player_2" => %{name: "Rex", role: "engineer", model: "zai/glm-5", status: "alive"},
        "player_3" => %{name: "Lyra", role: "crew", model: "anthropic/claude-x", status: "alive"}
      },
      action_history: [
        %{
          round: 1,
          actions: %{
            "player_1" => %{action: "fake_repair"},
            "player_2" => %{action: "repair"}
          }
        },
        %{round: 2, actions: %{"player_1" => %{action: "fake_repair"}}}
      ],
      vote_history: [
        %{round: 3, votes: %{"player_2" => "player_1", "player_3" => "player_1"}}
      ]
    }
  end
end
