defmodule LemonSimUi.WerewolfArenaTest do
  use ExUnit.Case, async: false

  alias LemonSim.Examples.Werewolf.League
  alias LemonSimUi.WerewolfArena

  @moduletag :tmp_dir

  @pool ["prov:model-a", "prov:model-b", "prov:model-c"]

  defp start_arena(ctx, opts \\ []) do
    test_pid = self()

    deps =
      Map.merge(
        %{
          start_sim: fn :werewolf, start_opts ->
            send(test_pid, {:start_sim, start_opts})
            {:ok, Keyword.get(start_opts, :sim_id, "ww_test#{System.unique_integer([:positive])}")}
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
          name: nil,
          enabled: true,
          models: @pool,
          player_count: 5,
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

    start_supervised!({WerewolfArena, config})
  end

  defp world_over(winner \\ "villagers") do
    %{
      status: "game_over",
      winner: winner,
      day_number: 2,
      players: %{
        "Aria" => %{role: "werewolf", model: "prov/model-a", status: "dead"},
        "Brin" => %{role: "seer", model: "prov/model-b", status: "alive"},
        "Cole" => %{role: "villager", model: "prov/model-c", status: "alive"}
      },
      vote_history: [],
      night_history: []
    }
  end

  defp world_update_event(sim_id, world) do
    LemonCore.Event.new(:sim_world_updated, %{state: %{world: world}}, %{sim_id: sim_id})
  end

  test "starts a game with a randomized plan on boot", ctx do
    arena = start_arena(ctx)

    assert_receive {:start_sim, start_opts}, 1_000
    assert length(start_opts[:model_specs]) == 5
    assert Enum.all?(start_opts[:model_specs], &(&1 in @pool))
    assert is_integer(start_opts[:seed])
    assert WerewolfArena.current_sim_id(arena)
  end

  test "records the game and starts the next one on game_over", ctx do
    arena = start_arena(ctx)
    assert_receive {:start_sim, _}, 1_000
    sim_id = WerewolfArena.current_sim_id(arena)

    LemonCore.Bus.subscribe(WerewolfArena.league_topic())
    send(arena, world_update_event(sim_id, world_over()))

    assert_receive %LemonCore.Event{type: :werewolf_league_updated}, 1_000
    assert {:ok, league} = League.load(ctx.tmp_dir)
    assert league["game_count"] == 1
    assert [game] = league["recent_games"]
    assert game["game_id"] == sim_id
    assert game["winner"] == "villagers"

    # Intermission elapses, then a fresh game begins.
    assert_receive {:start_sim, _}, 1_000
    next_id = WerewolfArena.current_sim_id(arena)
    assert next_id && next_id != sim_id
  end

  test "resumes a crashed game with backoff", ctx do
    test_pid = self()

    arena =
      start_arena(ctx,
        deps: %{
          get_state: fn sim_id ->
            send(test_pid, {:get_state, sim_id})
            %{world: %{status: "in_progress"}}
          end
        }
      )

    assert_receive {:start_sim, _}, 1_000
    sim_id = WerewolfArena.current_sim_id(arena)

    # Lobby says our sim vanished while the stored world is still in_progress.
    send(arena, LemonCore.Event.new(:sim_lobby_changed, %{}, %{}))

    assert_receive {:get_state, ^sim_id}, 1_000
    assert_receive {:resume_sim, ^sim_id}, 1_000
    assert WerewolfArena.current_sim_id(arena) == sim_id
  end

  test "abandons after resume attempts exhaust and starts fresh", ctx do
    arena =
      start_arena(ctx,
        deps: %{
          get_state: fn _sim_id -> %{world: %{status: "in_progress"}} end,
          resume_sim: fn _sim_id -> {:error, :nope} end
        }
      )

    assert_receive {:start_sim, _}, 1_000
    first_id = WerewolfArena.current_sim_id(arena)

    send(arena, LemonCore.Event.new(:sim_lobby_changed, %{}, %{}))

    # After resume attempts exhaust, a brand-new game is started.
    assert_receive {:start_sim, _}, 2_000
    assert WerewolfArena.current_sim_id(arena) != first_id
  end

  test "adopts an already-running werewolf sim instead of double-starting", ctx do
    arena =
      start_arena(ctx,
        deps: %{list_running: fn -> ["ww_existing"] end}
      )

    refute_receive {:start_sim, _}, 300
    assert WerewolfArena.current_sim_id(arena) == "ww_existing"
  end

  test "stays idle when disabled", ctx do
    arena = start_arena(ctx, enabled: false)

    refute_receive {:start_sim, _}, 300
    assert WerewolfArena.current_sim_id(arena) == nil
    assert WerewolfArena.status(arena).enabled == false
  end
end
