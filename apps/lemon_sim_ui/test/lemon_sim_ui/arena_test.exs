defmodule LemonSimUi.ArenaTest do
  use ExUnit.Case, async: false

  import LemonCore.Testing.AsyncHelpers, only: [assert_eventually: 1]

  alias LemonSim.Bench.League
  alias LemonSim.Kernel.State
  alias LemonSimUi.Arena

  @moduletag :tmp_dir

  @pool ["prov:model-a", "prov:model-b", "prov:model-c"]

  defp start_arena(ctx, opts \\ []) do
    test_pid = self()
    domain = Keyword.get(opts, :domain, :werewolf)

    deps =
      Map.merge(
        %{
          start_sim: fn ^domain, start_opts ->
            send(test_pid, {:start_sim, start_opts})
            prefix = Arena.sim_prefix(domain)

            {:ok,
             Keyword.get(start_opts, :sim_id, "#{prefix}t#{System.unique_integer([:positive])}")}
          end,
          resume_sim: fn sim_id ->
            send(test_pid, {:resume_sim, sim_id})
            {:ok, sim_id}
          end,
          abandon_sim: fn sim_id, reason ->
            send(test_pid, {:abandon_sim, sim_id, reason})
            :ok
          end,
          usage: fn _sim_id -> %{"totals" => %{"input_tokens" => 1}} end,
          list_running: fn -> [] end,
          get_state: fn _sim_id -> nil end,
          list_states: fn -> [] end,
          put_state: fn _state -> :ok end
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

  defp werewolf_world_over do
    %{
      status: "game_over",
      winner: "villagers",
      day_number: 3,
      players: %{
        "Aria" => %{role: "werewolf", model: "prov/model-a", status: "dead"},
        "Brin" => %{role: "seer", model: "prov/model-b", status: "alive"},
        "Cole" => %{role: "villager", model: "prov/model-c", status: "alive"}
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
    assert start_opts[:arena_domain] == "werewolf"
    assert Arena.current_sim_id(arena) =~ ~r/^ww_/
  end

  test "ignores lobby and world events before the first game is assigned", ctx do
    arena = start_arena(ctx, start_delay_ms: 1_000)

    send(arena, LemonCore.Event.new(:sim_lobby_changed, %{}, nil))
    send(arena, world_update_event("ww_not_current", %{status: "in_progress"}))

    Process.sleep(20)
    assert Process.alive?(arena)
    assert Arena.current_sim_id(arena) == nil
  end

  test "records the game via the domain adapter and starts the next one", ctx do
    arena = start_arena(ctx)
    assert_receive {:start_sim, _}, 1_000
    sim_id = Arena.current_sim_id(arena)

    LemonCore.Bus.subscribe(Arena.league_topic(:werewolf))
    send(arena, world_update_event(sim_id, werewolf_world_over()))

    assert_receive %LemonCore.Event{type: :arena_league_updated, meta: %{domain: :werewolf}},
                   1_000

    assert {:ok, league} = League.load(ctx.tmp_dir)
    assert league["scenario"] == "werewolf"
    assert league["game_count"] == 1
    assert [game] = league["recent_games"]
    assert game["winner"] == "villagers"
    assert "prov/model-b" in game["winning_models"]

    # Intermission elapses, then a fresh game begins.
    assert_receive {:start_sim, _}, 1_000
    assert Arena.current_sim_id(arena) != sim_id
  end

  test "retries a failed league write before starting the next game", ctx do
    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    record_game = fn _league_dir, _record, _max_game_records ->
      attempt = Agent.get_and_update(attempts, fn count -> {count + 1, count + 1} end)
      send(test_pid, {:record_attempt, attempt})

      if attempt == 1,
        do: {:error, :disk_unavailable},
        else: {:ok, %{"game_count" => 1}}
    end

    arena = start_arena(ctx, deps: %{record_game: record_game})
    assert_receive {:start_sim, _}, 1_000
    sim_id = Arena.current_sim_id(arena)
    send(arena, world_update_event(sim_id, werewolf_world_over()))

    assert_receive {:record_attempt, 1}, 1_000
    refute_receive {:start_sim, _}, 15
    assert_receive {:record_attempt, 2}, 1_000
    assert_receive {:start_sim, _}, 1_000
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
    assert_receive {:abandon_sim, ^first, _reason}, 2_000
    assert_receive {:start_sim, _}, 2_000
    assert Arena.current_sim_id(arena) != first
  end

  test "does not resume a run that exhausted its durable lifecycle", ctx do
    test_pid = self()

    arena =
      start_arena(ctx,
        deps: %{
          get_state: fn _sim_id ->
            %{
              world: %{status: "in_progress"},
              meta: %{run: %{status: "failed", resumable: false}}
            }
          end,
          resume_sim: fn sim_id ->
            send(test_pid, {:unexpected_resume, sim_id})
            {:ok, sim_id}
          end
        }
      )

    assert_receive {:start_sim, _}, 1_000
    first = Arena.current_sim_id(arena)
    send(arena, LemonCore.Event.new(:sim_lobby_changed, %{}, %{}))

    refute_receive {:unexpected_resume, ^first}, 100
    assert_receive {:start_sim, _}, 1_000
    assert Arena.current_sim_id(arena) != first
  end

  test "accepts a runner that SimManager already recovered", ctx do
    test_pid = self()

    arena =
      start_arena(ctx,
        deps: %{
          get_state: fn _sim_id ->
            %{
              world: %{status: "in_progress"},
              meta: %{run: %{status: "running", resumable: true}}
            }
          end,
          resume_sim: fn sim_id ->
            send(test_pid, {:resume_sim, sim_id})
            {:error, :already_running}
          end
        }
      )

    assert_receive {:start_sim, _}, 1_000
    sim_id = Arena.current_sim_id(arena)
    send(arena, LemonCore.Event.new(:sim_lobby_changed, %{}, %{}))

    assert_receive {:resume_sim, ^sim_id}, 1_000
    assert Arena.status(arena).current_status == :running
    assert Arena.current_sim_id(arena) == sim_id
  end

  test "adopts an already-running sim of its domain", ctx do
    arena =
      start_arena(ctx,
        deps: %{
          list_running: fn -> ["pkr_other", "ww_existing"] end,
          get_state: fn
            "ww_existing" ->
              State.new(
                sim_id: "ww_existing",
                world: %{status: "in_progress"},
                meta: %{run: %{arena_domain: "werewolf"}}
              )

            _sim_id ->
              nil
          end
        }
      )

    assert_eventually(fn -> Arena.current_sim_id(arena) == "ww_existing" end)
    refute_receive {:start_sim, _}, 300
    assert Arena.current_sim_id(arena) == "ww_existing"
  end

  test "does not reconcile a manual terminal simulation into the arena league", ctx do
    test_pid = self()

    manual_state =
      State.new(
        sim_id: "ww_manual_game",
        world: werewolf_world_over(),
        meta: %{run: %{domain: "werewolf", status: "completed", resumable: false}}
      )

    start_arena(ctx,
      deps: %{
        list_states: fn -> [manual_state] end,
        record_game: fn _league_dir, record, _max_game_records ->
          send(test_pid, {:unexpected_record, record["game_id"]})
          {:ok, %{"game_count" => 1}}
        end
      }
    )

    assert_receive {:start_sim, _}, 1_000
    refute_receive {:unexpected_record, "ww_manual_game"}, 100
  end

  test "waits for the runner's final write before persisting the league marker", ctx do
    test_pid = self()
    {:ok, running} = Agent.start_link(fn -> true end)

    terminal_state =
      State.new(
        sim_id: "ww_marker_race",
        world: werewolf_world_over(),
        meta: %{
          run: %{
            domain: "werewolf",
            arena_domain: "werewolf",
            status: "completed",
            resumable: false,
            finished_at_ms: System.system_time(:millisecond)
          }
        }
      )

    {:ok, persisted} = Agent.start_link(fn -> terminal_state end)

    arena =
      start_arena(ctx,
        deps: %{
          list_running: fn -> if Agent.get(running, & &1), do: ["ww_marker_race"], else: [] end,
          get_state: fn "ww_marker_race" -> Agent.get(persisted, & &1) end,
          put_state: fn state ->
            Agent.update(persisted, fn _ -> state end)
            send(test_pid, {:league_marker, state})
            :ok
          end,
          record_game: fn _league_dir, record, _max_game_records ->
            send(test_pid, {:record_game, record["game_id"]})
            {:ok, %{"game_count" => 1}}
          end
        }
      )

    refute_receive {:start_sim, _}, 100
    send(arena, world_update_event("ww_marker_race", werewolf_world_over()))
    assert_receive {:record_game, "ww_marker_race"}, 1_000
    refute_receive {:league_marker, _state}, 100

    Agent.update(running, fn _ -> false end)
    Agent.update(persisted, fn _ -> terminal_state end)
    send(arena, LemonCore.Event.new(:sim_lobby_changed, %{}, %{}))

    assert_receive {:league_marker, marked_state}, 1_000
    assert marked_state.meta.run.arena_league_recorded_domain == "werewolf"
  end

  test "reconciles and durably marks a terminal game before starting another", ctx do
    test_pid = self()
    finished_at_ms = System.system_time(:millisecond) - 1_000

    terminal_state =
      State.new(
        sim_id: "ww_unrecorded",
        world: werewolf_world_over(),
        meta: %{
          run: %{
            domain: "werewolf",
            arena_domain: "werewolf",
            seed: 91,
            started_at_ms: finished_at_ms - 5_000,
            finished_at_ms: finished_at_ms,
            status: "completed",
            resumable: false
          }
        }
      )

    {:ok, persisted} = Agent.start_link(fn -> terminal_state end)

    arena =
      start_arena(ctx,
        deps: %{
          list_states: fn -> [Agent.get(persisted, & &1)] end,
          get_state: fn
            "ww_unrecorded" -> Agent.get(persisted, & &1)
            _sim_id -> nil
          end,
          put_state: fn state ->
            Agent.update(persisted, fn _ -> state end)
            send(test_pid, {:league_marker, state})
            :ok
          end,
          record_game: fn _league_dir, record, _max_game_records ->
            send(test_pid, {:record_game, record})
            {:ok, %{"game_count" => 1}}
          end
        }
      )

    assert_receive {:record_game, %{"game_id" => "ww_unrecorded", "seed" => 91} = record},
                   1_000

    assert record["recorded_at"] ==
             finished_at_ms
             |> DateTime.from_unix!(:millisecond)
             |> DateTime.truncate(:second)
             |> DateTime.to_iso8601()

    assert record["duration_ms"] == 5_000

    assert_receive {:league_marker, marked_state}, 1_000
    assert marked_state.meta.run.arena_league_recorded_domain == "werewolf"
    assert is_integer(marked_state.meta.run.arena_league_recorded_at_ms)

    assert_receive {:start_sim, _}, 1_000
    assert Arena.current_sim_id(arena) != "ww_unrecorded"
  end

  test "restart reconciliation preserves an already-written game record", ctx do
    test_pid = self()

    terminal_state =
      State.new(
        sim_id: "ww_existing_record",
        world: werewolf_world_over(),
        meta: %{
          run: %{
            domain: "werewolf",
            arena_domain: "werewolf",
            status: "completed",
            resumable: false,
            finished_at_ms: System.system_time(:millisecond)
          }
        }
      )

    {:ok, adapter} = LemonSim.Bench.League.Registry.fetch(:werewolf)

    original_record =
      League.game_record(adapter, terminal_state.world,
        game_id: terminal_state.sim_id,
        recorded_at: "2026-07-10T12:00:00Z",
        usage: %{"totals" => %{"input_tokens" => 777}}
      )

    assert {:ok, _league} = League.record_game!(ctx.tmp_dir, original_record)
    {:ok, persisted} = Agent.start_link(fn -> terminal_state end)

    start_arena(ctx,
      deps: %{
        list_states: fn -> [Agent.get(persisted, & &1)] end,
        get_state: fn
          "ww_existing_record" -> Agent.get(persisted, & &1)
          _sim_id -> nil
        end,
        put_state: fn state ->
          Agent.update(persisted, fn _ -> state end)
          send(test_pid, {:league_marker, state})
          :ok
        end,
        record_game: fn _league_dir, record, _max_game_records ->
          send(test_pid, {:unexpected_rewrite, record})
          {:ok, %{"game_count" => 1}}
        end
      }
    )

    assert_receive {:league_marker, _state}, 1_000
    refute_receive {:unexpected_rewrite, _record}, 100

    assert [preserved_record] = League.load_games(ctx.tmp_dir)
    assert preserved_record["recorded_at"] == "2026-07-10T12:00:00Z"
    assert preserved_record["usage"]["totals"]["input_tokens"] == 777
  end

  test "retries a failed durable league marker without rewriting the game", ctx do
    test_pid = self()

    terminal_state =
      State.new(
        sim_id: "ww_marker_retry",
        world: werewolf_world_over(),
        meta: %{
          run: %{
            domain: "werewolf",
            arena_domain: "werewolf",
            status: "completed",
            resumable: false,
            finished_at_ms: System.system_time(:millisecond)
          }
        }
      )

    {:ok, persisted} = Agent.start_link(fn -> terminal_state end)
    {:ok, marker_attempts} = Agent.start_link(fn -> 0 end)

    start_arena(ctx,
      deps: %{
        list_states: fn -> [Agent.get(persisted, & &1)] end,
        get_state: fn
          "ww_marker_retry" -> Agent.get(persisted, & &1)
          _sim_id -> nil
        end,
        put_state: fn state ->
          attempt = Agent.get_and_update(marker_attempts, fn count -> {count + 1, count + 1} end)
          send(test_pid, {:marker_attempt, attempt})

          if attempt == 1 do
            {:error, :disk_unavailable}
          else
            Agent.update(persisted, fn _ -> state end)
            :ok
          end
        end,
        record_game: fn _league_dir, record, _max_game_records ->
          send(test_pid, {:record_game, record["game_id"]})
          {:ok, %{"game_count" => 1}}
        end
      }
    )

    assert_receive {:record_game, "ww_marker_retry"}, 1_000
    assert_receive {:marker_attempt, 1}, 1_000
    assert_receive {:marker_attempt, 2}, 1_000
    refute_receive {:record_game, "ww_marker_retry"}, 100
    assert_receive {:start_sim, _}, 1_000
  end

  test "stays idle when disabled", ctx do
    arena = start_arena(ctx, enabled: false)

    refute_receive {:start_sim, _}, 300
    assert Arena.current_sim_id(arena) == nil
    assert Arena.status(arena).enabled == false
  end

  test "adoption preserves the persisted seed and original start time", ctx do
    test_pid = self()
    started_at_ms = System.system_time(:millisecond) - 5_000

    arena =
      start_arena(ctx,
        deps: %{
          list_running: fn -> ["ww_existing"] end,
          get_state: fn _sim_id ->
            State.new(
              sim_id: "ww_existing",
              world: %{status: "in_progress"},
              meta: %{
                run: %{
                  arena_domain: "werewolf",
                  seed: 4242,
                  started_at_ms: started_at_ms
                }
              }
            )
          end,
          record_game: fn _league_dir, record, _max_game_records ->
            send(test_pid, {:record, record})
            {:ok, %{"game_count" => 1}}
          end
        }
      )

    refute_receive {:start_sim, _}, 300
    assert Arena.status(arena).current_seed == 4242

    send(arena, world_update_event("ww_existing", werewolf_world_over()))
    assert_receive {:record, record}, 1_000
    assert record["seed"] == 4242
    assert record["duration_ms"] >= 5_000
  end

  test "werewolf domain works through the same generic path", ctx do
    arena = start_arena(ctx, domain: :werewolf, player_count: 4)
    assert_receive {:start_sim, start_opts}, 1_000
    assert length(start_opts[:model_specs]) == 4
    assert start_opts[:model_specs] == @pool ++ ["prov:model-a"]
    assert start_opts[:balanced_roles?]
    assert start_opts[:role_rotation_index] == 0
    assert Arena.current_sim_id(arena) =~ ~r/^ww_/
  end

  test "poker arena seats six players rather than the solo registry default", ctx do
    assert LemonSim.Bench.Domains.get("poker").default_player_count == 4
    parent = self()

    start_supervised!(
      {Arena,
       domain: :poker,
       name: nil,
       enabled: true,
       models: @pool,
       league_dir: ctx.tmp_dir,
       start_delay_ms: 0,
       deps: %{
         list_running: fn -> [] end,
         list_states: fn -> [] end,
         start_sim: fn :poker, opts ->
           send(parent, {:default_poker_seats, opts})
           {:ok, "pkr_default_seats"}
         end
       }}
    )

    assert_receive {:default_poker_seats, opts}, 1_000
    assert opts[:player_count] == 6
    assert Enum.sort(opts[:model_specs]) == Enum.sort(@pool ++ @pool)
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
    assert Arena.sim_prefix(:werewolf) == "ww_"
    assert Arena.sim_prefix(:poker) == "pkr_"
    assert Arena.league_topic(:poker) == "arena:poker:league"
    assert Arena.league_dir(:poker) =~ "poker_league"
    assert :werewolf in Arena.domains()
    assert :poker in Arena.domains()
  end
end
