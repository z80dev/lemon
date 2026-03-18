defmodule LemonSimUi.SpectatorLiveTest do
  use LemonSimUi.ConnCase

  import Phoenix.LiveViewTest

  test "shows not found for nonexistent sim", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/watch/nonexistent_sim_id")
    assert html =~ "Simulation Not Found"
    assert html =~ "nonexistent_sim_id"
  end

  test "shows not supported for non-werewolf sim", %{conn: conn} do
    # Create a tic-tac-toe sim (not werewolf)
    state =
      LemonSim.State.new(
        sim_id: "test_spectator_ttt",
        world: LemonSim.Examples.TicTacToe.initial_world()
      )

    LemonSim.Store.put_state(state)

    {:ok, _view, html} = live(conn, "/watch/test_spectator_ttt")
    assert html =~ "Spectator Mode Unavailable"
    assert html =~ "Tic Tac Toe"

    LemonSim.Store.delete_state("test_spectator_ttt")
  end

  test "renders spectator view for werewolf sim", %{conn: conn} do
    world = LemonSim.Examples.Werewolf.initial_world(player_count: 5)

    state =
      LemonSim.State.new(
        sim_id: "test_spectator_ww",
        world: world
      )

    LemonSim.Store.put_state(state)

    {:ok, _view, html} = live(conn, "/watch/test_spectator_ww")
    assert html =~ "test_spectator_ww"
    assert html =~ "Werewolf"
    assert html =~ "Day"
    # Should NOT have admin controls
    refute html =~ "Abort Sim"
    refute html =~ "RAW_STATE_DUMP"
    refute html =~ "AGENT STRATEGY"
    refute html =~ "DATA BANKS"

    LemonSim.Store.delete_state("test_spectator_ww")
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
      LemonSim.State.new(
        sim_id: "test_spectator_ww_lore",
        world: world
      )

    LemonSim.Store.put_state(state)

    {:ok, view, _html} = live(conn, "/watch/test_spectator_ww_lore")
    html = render(view)
    assert html =~ "Elara Thornberry"
    assert html =~ "herbalist"
    assert html =~ "VILLAGERS"

    LemonSim.Store.delete_state("test_spectator_ww_lore")
  end

  test "shows LIVE badge for running sims", %{conn: conn} do
    world = LemonSim.Examples.Werewolf.initial_world(player_count: 5)

    state =
      LemonSim.State.new(
        sim_id: "test_spectator_live_badge",
        world: world
      )

    LemonSim.Store.put_state(state)

    {:ok, _view, html} = live(conn, "/watch/test_spectator_live_badge")
    # Since the sim is not running via SimManager, should show STOPPED
    assert html =~ "STOPPED"

    LemonSim.Store.delete_state("test_spectator_live_badge")
  end

  test "updates running badge when lobby changes", %{conn: conn} do
    sim_id = "test_spectator_lobby_updates"

    state =
      LemonSim.State.new(
        sim_id: sim_id,
        world: LemonSim.Examples.Werewolf.initial_world(player_count: 5)
      )

    LemonSim.Store.put_state(state)

    original_manager_state = :sys.get_state(LemonSimUi.SimManager)

    on_exit(fn ->
      LemonSim.Store.delete_state(sim_id)
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
end
