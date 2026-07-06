defmodule LemonSimUi.ArenaTest do
  use ExUnit.Case, async: false

  alias LemonSim.Bench.League
  alias LemonSimUi.Arena

  @moduletag :tmp_dir

  @pool ["prov:model-a", "prov:model-b", "prov:model-c"]

  defp start_arena(ctx, opts \\ []) do
    test_pid = self()
    domain = Keyword.get(opts, :domain, :space_station)

    deps =
      Map.merge(
        %{
          start_sim: fn ^domain, start_opts ->
            send(test_pid, {:start_sim, start_opts})
            prefix = Arena.sim_prefix(domain)
            {:ok, Keyword.get(start_opts, :sim_id, "#{prefix}t#{System.unique_integer([:positive])}")}
          end,
          resume_sim: fn sim_id ->
            send(test_pid, {:resume_sim, sim_id})
            {:ok, sim_id}
          end,
          usage: fn _sim_id -> %{"totals" => %{"input_tokens" => 1}} end,
          list_running: fn -> [] end,
          get_state: fn _sim_id -> nil end
        },
        Keyword.get(opts, :deps, %{})
      )

    config =
      Keyword.merge(
        [
          domain: domain,
          name: nil,
          enabled: true,
          models: @pool,
          player_count: 3,
          league_dir: ctx.tmp_dir,
          start_delay_ms: 10,
          game_delay_ms: 25,
          retry_start_ms: 25,
          resume_backoff_ms: 10,
          tick_ms: 60_000,
          deps: deps
        ],
        Keyword.delete(opts, :deps)
      )

    start_supervised!({Arena, config})
  end

  defp space_station_world_over do
    %{
      status: "game_over",
      winner: "crew",
      round: 4,
      players: %{
        "player_1" => %{role: "saboteur", model: "prov/model-a", status: "ejected"},
        "player_2" => %{role: "engineer", model: "prov/model-b", status: "alive"},
        "player_3" => %{role: "crew", model: "prov/model-c", status: "alive"}
      },
      action_history: [],
      vote_history: []
    }
  end

  defp poker_world_over do
    %{
      status: "game_over",
      winner: "player_1",
      winner_ids: ["player_1"],
      completed_hands: 8,
      table: %{big_blind: 100, small_blind: 50},
      players: %{
        "player_1" => %{seat: 1, model: "prov/model-a"},
        "player_2" => %{seat: 2, model: "prov/model-b"},
        "player_3" => %{seat: 3, model: "prov/model-c"}
      },
      chip_counts: [
        %{"seat" => 1, "player_id" => "player_1", "stack" => 3500, "status" => "active"},
        %{"seat" => 2, "player_id" => "player_2", "stack" => 1800, "status" => "active"},
        %{"seat" => 3, "player_id" => "player_3", "stack" => 700, "status" => "active"}
      ],
      player_stats: %{
        "player_1" => %{starting_stack: 2000, hands_played: 8, hands_won: 4},
        "player_2" => %{starting_stack: 2000, hands_played: 8, hands_won: 3},
        "player_3" => %{starting_stack: 2000, hands_played: 8, hands_won: 1}
      }
    }
  end

  defp world_update_event(sim_id, world) do
    LemonCore.Event.new(:sim_world_updated, %{state: %{world: world}}, %{sim_id: sim_id})
  end

  test "starts a game with a randomized plan on boot", ctx do
    arena = start_arena(ctx)

    assert_receive {:start_sim, start_opts}, 1_000
    assert length(start_opts[:model_specs]) == 3
    assert is_integer(start_opts[:seed])
    assert Arena.current_sim_id(arena) =~ ~r/^spc_/
  end

  test "records the game via the domain adapter and starts the next one", ctx do
    arena = start_arena(ctx)
    assert_receive {:start_sim, _}, 1_000
    sim_id = Arena.current_sim_id(arena)

    LemonCore.Bus.subscribe(Arena.league_topic(:space_station))
    send(arena, world_update_event(sim_id, space_station_world_over()))

    assert_receive %LemonCore.Event{type: :arena_league_updated, meta: %{domain: :space_station}},
                   1_000

    assert {:ok, league} = League.load(ctx.tmp_dir)
    assert league["scenario"] == "space_station"
    assert league["game_count"] == 1
    assert [game] = league["recent_games"]
    assert game["winner"] == "crew"
    assert "prov/model-b" in game["winning_models"]

    # Intermission elapses, then a fresh game begins.
    assert_receive {:start_sim, _}, 1_000
    assert Arena.current_sim_id(arena) != sim_id
  end

  test "resumes a crashed game with backoff, then abandons and replaces", ctx do
    arena =
      start_arena(ctx,
        deps: %{
          get_state: fn _sim_id -> %{world: %{status: "in_progress"}} end,
          resume_sim: fn _sim_id -> {:error, :nope} end
        }
      )

    assert_receive {:start_sim, _}, 1_000
    first = Arena.current_sim_id(arena)

    send(arena, LemonCore.Event.new(:sim_lobby_changed, %{}, %{}))

    # Resume attempts exhaust, then a brand-new game starts.
    assert_receive {:start_sim, _}, 2_000
    assert Arena.current_sim_id(arena) != first
  end

  test "adopts an already-running sim of its domain", ctx do
    arena =
      start_arena(ctx,
        deps: %{list_running: fn -> ["ww_other", "spc_existing"] end}
      )

    refute_receive {:start_sim, _}, 300
    assert Arena.current_sim_id(arena) == "spc_existing"
  end

  test "stays idle when disabled", ctx do
    arena = start_arena(ctx, enabled: false)

    refute_receive {:start_sim, _}, 300
    assert Arena.current_sim_id(arena) == nil
    assert Arena.status(arena).enabled == false
  end

  test "werewolf domain works through the same generic path", ctx do
    arena = start_arena(ctx, domain: :werewolf, player_count: 4)
    assert_receive {:start_sim, start_opts}, 1_000
    assert length(start_opts[:model_specs]) == 4
    assert Arena.current_sim_id(arena) =~ ~r/^ww_/
  end

  test "poker domain records ranked games through the generic path", ctx do
    arena = start_arena(ctx, domain: :poker)
    assert_receive {:start_sim, start_opts}, 1_000
    assert length(start_opts[:model_specs]) == 3

    sim_id = Arena.current_sim_id(arena)
    assert sim_id =~ ~r/^pkr_/

    LemonCore.Bus.subscribe(Arena.league_topic(:poker))
    send(arena, world_update_event(sim_id, poker_world_over()))

    assert_receive %LemonCore.Event{type: :arena_league_updated, meta: %{domain: :poker}},
                   1_000

    assert {:ok, league} = League.load(ctx.tmp_dir)
    assert league["scenario"] == "poker"
    assert league["mode"] == "ranked"
    assert league["game_count"] == 1
    assert [game] = league["recent_games"]
    assert game["winner"] == "player_1"
    assert game["winning_models"] == ["prov/model-a"]
  end

  test "domain helpers expose prefixes and league dirs" do
    assert Arena.sim_prefix(:stock_market) == "stk_"
    assert Arena.sim_prefix(:survivor) == "srv_"
    assert Arena.sim_prefix(:poker) == "pkr_"
    assert Arena.league_topic(:stock_market) == "arena:stock_market:league"
    assert Arena.league_dir(:survivor) =~ "survivor_league"
    assert :space_station in Arena.domains()
    assert :poker in Arena.domains()
  end
end
