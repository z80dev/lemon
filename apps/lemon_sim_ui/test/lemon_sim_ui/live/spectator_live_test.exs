defmodule LemonSimUi.SpectatorLiveTest do
  use LemonSimUi.ConnCase

  import Phoenix.LiveViewTest

  alias Ai.Types.{Model, ModelCost, Usage}
  alias LemonSim.Kernel.State
  alias LemonSim.LLM.Usage, as: SimUsage

  @artifact_registry Path.join(System.tmp_dir!(), "lemon_vending_bench_artifact_registry.json")

  test "shows not found for nonexistent sim", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/watch/nonexistent_sim_id")
    assert html =~ "Simulation Not Found"
    assert html =~ "nonexistent_sim_id"
  end

  test "shows not supported for non-werewolf sim", %{conn: conn} do
    # Create a tic-tac-toe sim (not werewolf)
    state =
      LemonSim.Kernel.State.new(
        sim_id: "test_spectator_ttt",
        world: LemonSim.Examples.TicTacToe.initial_world()
      )

    LemonSim.Kernel.Store.put_state(state)

    {:ok, _view, html} = live(conn, "/watch/test_spectator_ttt")
    assert html =~ "Spectator Mode Unavailable"
    assert html =~ "Tic Tac Toe"

    LemonSim.Kernel.Store.delete_state("test_spectator_ttt")
  end

  test "renders spectator view for werewolf sim", %{conn: conn} do
    world = LemonSim.Examples.Werewolf.initial_world(player_count: 5)

    state =
      LemonSim.Kernel.State.new(
        sim_id: "test_spectator_ww",
        world: world
      )

    LemonSim.Kernel.Store.put_state(state)

    {:ok, _view, html} = live(conn, "/watch/test_spectator_ww")
    assert html =~ "test_spectator_ww"
    assert html =~ "Werewolf"
    assert html =~ "Day"
    # Should NOT have admin controls
    refute html =~ "Abort Sim"
    refute html =~ "RAW_STATE_DUMP"
    refute html =~ "AGENT STRATEGY"
    refute html =~ "DATA BANKS"

    LemonSim.Kernel.Store.delete_state("test_spectator_ww")
  end

  test "renders spectator view for vending bench sim", %{conn: conn} do
    state =
      LemonSim.Examples.VendingBench.initial_state(
        sim_id: "test_spectator_vb",
        max_days: 365
      )

    LemonSim.Kernel.Store.put_state(state)

    {:ok, _view, html} = live(conn, "/watch/test_spectator_vb")
    assert html =~ "test_spectator_vb"
    assert html =~ "VendingBench"
    assert html =~ "VENDBENCH LIVE"
    assert html =~ "Day 1/365"
    refute html =~ "Abort Sim"
    refute html =~ "RAW_STATE_DUMP"
    refute html =~ "AGENT STRATEGY"
    refute html =~ "DATA BANKS"

    LemonSim.Kernel.Store.delete_state("test_spectator_vb")
  end

  test "renders spectator view for tcg shop sim", %{conn: conn} do
    state =
      LemonSim.Examples.TcgShop.initial_state(
        sim_id: "test_spectator_tcg",
        max_days: 14,
        seed: 11
      )

    LemonSim.Kernel.Store.put_state(state)

    {:ok, _view, html} = live(conn, "/watch/test_spectator_tcg")
    assert html =~ "test_spectator_tcg"
    assert html =~ "TCG Shop"
    assert html =~ "Local Game Store"
    assert html =~ "Day 1/14"
    refute html =~ "Abort Sim"
    refute html =~ "RAW_STATE_DUMP"
    refute html =~ "AGENT STRATEGY"
    refute html =~ "DATA BANKS"

    LemonSim.Kernel.Store.delete_state("test_spectator_tcg")
  end

  test "renders vending bench spectator view from checkpoint artifacts", %{conn: conn} do
    sim_id = "test_spectator_vb_artifact"

    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "test_spectator_vb_artifact_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(artifact_dir)
    LemonSim.Kernel.Store.delete_state(sim_id)

    assert {:ok, _result} =
             LemonSim.Examples.VendingBench.run_offline_strategy("baseline",
               sim_id: sim_id,
               max_days: 2,
               seed: 1,
               driver_max_turns: 4,
               artifact_dir: artifact_dir
             )

    LemonSim.Kernel.Store.delete_state(sim_id)

    {:ok, _view, html} = live(conn, "/watch/#{sim_id}")
    assert html =~ sim_id
    assert html =~ "VendingBench"
    assert html =~ "VENDBENCH LIVE"

    File.rm_rf!(artifact_dir)
  end

  test "renders usage panel from checkpoint artifacts", %{conn: conn} do
    sim_id = "test_spectator_usage_artifact"
    original_registry = File.read(@artifact_registry)

    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "test_spectator_usage_artifact_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_registry(original_registry)
      File.rm_rf!(artifact_dir)
      LemonSim.Kernel.Store.delete_state(sim_id)
    end)

    File.rm_rf!(artifact_dir)
    File.mkdir_p!(artifact_dir)
    LemonSim.Kernel.Store.delete_state(sim_id)

    world =
      LemonSim.Examples.VendingBench.initial_state(sim_id: sim_id, max_days: 2).world
      |> Map.put(:status, "complete")

    File.write!(Path.join(artifact_dir, "final_world.json"), Jason.encode!(world))

    File.write!(
      Path.join(artifact_dir, "usage.json"),
      Jason.encode!(%{
        "schema" => "lemon_sim.usage.v1",
        "sim_id" => sim_id,
        "totals" => %{
          "input_tokens" => 1_200,
          "output_tokens" => 345,
          "cache_read_tokens" => 10,
          "cache_write_tokens" => 5,
          "decisions" => 7,
          "cost_usd" => nil
        },
        "actors" => %{
          "operator" => %{
            "model_id" => "openai:gpt-test",
            "input_tokens" => 1_000,
            "output_tokens" => 300,
            "cache_read_tokens" => 10,
            "cache_write_tokens" => 5,
            "decisions" => 5,
            "cost_usd" => nil
          },
          "physical_worker" => %{
            "model_id" => "anthropic:claude-test",
            "input_tokens" => 200,
            "output_tokens" => 45,
            "cache_read_tokens" => 0,
            "cache_write_tokens" => 0,
            "decisions" => 2,
            "cost_usd" => 0.03
          }
        }
      })
    )

    File.write!(@artifact_registry, Jason.encode!(%{sim_id => artifact_dir}))

    {:ok, view, _html} = live(conn, "/watch/#{sim_id}")
    html = render(view)

    assert html =~ "Usage"
    assert html =~ "1,560 tokens"
    assert html =~ "1,200"
    assert html =~ "345"
    assert html =~ "operator"
    assert html =~ "openai:gpt-test"
    assert html =~ "physical_worker"
    assert html =~ "$0.03"
    assert html =~ "—"
  end

  test "renders usage panel from a live usage collector", %{conn: conn} do
    sim_id = "test_spectator_live_usage"
    original_manager_state = :sys.get_state(LemonSimUi.SimManager)

    {:ok, collector} = SimUsage.start_link(sim_id)

    model = %Model{
      id: "unknown-live",
      name: "Unknown Live",
      provider: :test,
      cost: %ModelCost{}
    }

    SimUsage.record_decision(collector, "operator", model)
    SimUsage.record_response(collector, "operator", model, %Usage{input: 100, output: 50})
    SimUsage.record_external_decision(collector, "physical_worker", "external-worker")

    state =
      LemonSim.Examples.VendingBench.initial_state(
        sim_id: sim_id,
        max_days: 2
      )

    LemonSim.Kernel.Store.put_state(state)

    :sys.replace_state(LemonSimUi.SimManager, fn manager_state ->
      put_in(manager_state.runners[sim_id], %{
        ref: self(),
        domain: :vending_bench,
        usage_collector: collector
      })
    end)

    on_exit(fn ->
      :sys.replace_state(LemonSimUi.SimManager, fn _ -> original_manager_state end)
      if Process.alive?(collector), do: Agent.stop(collector)
      LemonSim.Kernel.Store.delete_state(sim_id)
    end)

    {:ok, view, _html} = live(conn, "/watch/#{sim_id}")
    html = render(view)

    assert html =~ "Usage"
    assert html =~ "150 tokens"
    assert html =~ "100"
    assert html =~ "50"
    assert html =~ "operator"
    assert html =~ "test:unknown-live"
    assert html =~ "physical_worker"
    assert html =~ "external-worker"
    assert html =~ "—"

    usage_html = view |> element("#usage-panel") |> render()
    assert usage_html =~ "—"
    refute usage_html =~ "$0.00"
  end

  test "uses arena leader world for vending bench spectator header", %{conn: conn} do
    sim_id = "test_spectator_vb_arena_header"

    leader_world =
      LemonSim.Examples.VendingBench.initial_state(sim_id: "#{sim_id}_leader", max_days: 365).world
      |> Map.merge(%{
        day_number: 365,
        max_days: 365,
        phase: "operator_turn",
        status: "complete"
      })

    state =
      State.new(
        sim_id: sim_id,
        world: %{
          "mode" => "vending_bench_arena",
          "day_number" => 365,
          "max_days" => 365,
          "status" => "complete",
          "arena_agents" => [
            %{
              "agent_id" => "alex",
              "agent_name" => "Alex Market",
              "world" => leader_world
            }
          ]
        }
      )

    LemonSim.Kernel.Store.put_state(state)

    on_exit(fn ->
      LemonSim.Kernel.Store.delete_state(sim_id)
    end)

    {:ok, _view, html} = live(conn, "/watch/#{sim_id}")
    assert html =~ "Day 365/365"
    assert html =~ "Operator Turn"
    refute html =~ "Operating"
  end

  test "renders character profiles in bio strip when present", %{conn: conn} do
    world = LemonSim.Examples.Werewolf.initial_world(player_count: 5)

    # Use actual player IDs from the generated world (names like "Alice", "Bram", etc.)
    first_player_id = world.players |> Map.keys() |> Enum.sort() |> List.first()

    # Inject character profiles keyed by actual player IDs
    world =
      Map.put(world, :character_profiles, %{
        first_player_id => %{
          "full_name" => "Elara Thornberry",
          "occupation" => "herbalist",
          "appearance" => "Tall with auburn hair",
          "personality" => "Kind and observant",
          "motivation" => "Protect the village",
          "backstory" => "Born in the village"
        }
      })

    state =
      LemonSim.Kernel.State.new(
        sim_id: "test_spectator_ww_lore",
        world: world
      )

    LemonSim.Kernel.Store.put_state(state)

    {:ok, view, _html} = live(conn, "/watch/test_spectator_ww_lore")
    html = render(view)
    assert html =~ "Elara Thornberry"
    assert html =~ "herbalist"
    assert html =~ "VILLAGERS"

    LemonSim.Kernel.Store.delete_state("test_spectator_ww_lore")
  end

  test "shows LIVE badge for running sims", %{conn: conn} do
    world = LemonSim.Examples.Werewolf.initial_world(player_count: 5)

    state =
      LemonSim.Kernel.State.new(
        sim_id: "test_spectator_live_badge",
        world: world
      )

    LemonSim.Kernel.Store.put_state(state)

    {:ok, _view, html} = live(conn, "/watch/test_spectator_live_badge")
    # Since the sim is not running via SimManager, should show STOPPED
    assert html =~ "STOPPED"

    LemonSim.Kernel.Store.delete_state("test_spectator_live_badge")
  end

  test "updates running badge when lobby changes", %{conn: conn} do
    sim_id = "test_spectator_lobby_updates"

    state =
      LemonSim.Kernel.State.new(
        sim_id: sim_id,
        world: LemonSim.Examples.Werewolf.initial_world(player_count: 5)
      )

    LemonSim.Kernel.Store.put_state(state)

    original_manager_state = :sys.get_state(LemonSimUi.SimManager)

    on_exit(fn ->
      LemonSim.Kernel.Store.delete_state(sim_id)
      :sys.replace_state(LemonSimUi.SimManager, fn _ -> original_manager_state end)
    end)

    {:ok, view, html} = live(conn, "/watch/#{sim_id}")
    assert html =~ "STOPPED"

    :sys.replace_state(LemonSimUi.SimManager, fn sim_manager_state ->
      put_in(sim_manager_state.runners[sim_id], %{ref: self(), domain: :werewolf})
    end)

    LemonCore.Bus.broadcast(
      LemonSimUi.SimManager.lobby_topic(),
      LemonCore.Event.new(:sim_lobby_changed, %{}, %{})
    )

    assert render(view) =~ "LIVE"
    refute render(view) =~ "STOPPED"
  end

  test "buffers werewolf snapshots so fast updates do not skip straight to the latest phase",
       %{conn: conn} do
    sim_id = "test_spectator_buffered_phase"
    world = LemonSim.Examples.Werewolf.initial_world(player_count: 5)

    state0 = State.new(sim_id: sim_id, version: 0, world: world)

    wolf_chat =
      [
        %{
          player: "Alice",
          message: "Keep the village arguing. If they split tomorrow, we stay invisible."
        }
      ]

    state1 =
      State.new(
        sim_id: sim_id,
        version: 1,
        world: %{
          state0.world
          | phase: "wolf_discussion",
            active_actor_id: "Alice",
            wolf_chat_transcript: wolf_chat
        }
      )

    state2 =
      State.new(
        sim_id: sim_id,
        version: 2,
        world: %{
          state1.world
          | phase: "night",
            active_actor_id: "Alice",
            night_actions: %{"Alice" => %{action: "choose_victim", target: "Bram"}}
        }
      )

    LemonSim.Kernel.Store.put_state(state0)

    on_exit(fn ->
      LemonSim.Kernel.Store.delete_state(sim_id)
    end)

    {:ok, view, _html} = live(conn, "/watch/#{sim_id}")

    # Put the store ahead of the UI, then send exact snapshots over pubsub.
    LemonSim.Kernel.Store.put_state(state2)

    LemonCore.Bus.broadcast(
      LemonSim.Kernel.Bus.sim_topic(sim_id),
      LemonCore.Event.new(:sim_world_updated, %{state: state1}, %{sim_id: sim_id})
    )

    LemonCore.Bus.broadcast(
      LemonSim.Kernel.Bus.sim_topic(sim_id),
      LemonCore.Event.new(:sim_world_updated, %{state: state2}, %{sim_id: sim_id})
    )

    assert_eventually(fn ->
      html = render(view)
      html =~ "Wolf Den" and html =~ "The pack plots"
    end)

    html = render(view)
    assert html =~ "Wolf Den"
    refute html =~ "Nightfall"
  end

  defp assert_eventually(fun, attempts \\ 30)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp restore_registry({:ok, body}), do: File.write!(@artifact_registry, body)
  defp restore_registry({:error, _reason}), do: File.rm(@artifact_registry)
end
