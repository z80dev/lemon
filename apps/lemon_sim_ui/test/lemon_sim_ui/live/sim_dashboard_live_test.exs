defmodule LemonSimUi.SimDashboardLiveTest do
  use LemonSimUi.ConnCase

  import Phoenix.LiveViewTest

  test "mounts with no sims", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "LemonSim"
    assert html =~ "No simulation selected"
    assert render(view) =~ "0 simulations"
  end

  test "shows sim list when sims exist", %{conn: conn} do
    state =
      LemonSim.State.new(
        sim_id: "test_ttt_1",
        world: LemonSim.Examples.TicTacToe.initial_world()
      )

    LemonSim.Store.put_state(state)

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "test_ttt_1"
    assert html =~ "Tic Tac Toe"

    LemonSim.Store.delete_state("test_ttt_1")
  end

  test "navigates to sim detail", %{conn: conn} do
    state =
      LemonSim.State.new(
        sim_id: "test_ttt_2",
        world: LemonSim.Examples.TicTacToe.initial_world()
      )

    LemonSim.Store.put_state(state)

    {:ok, view, _html} = live(conn, "/")
    html = render_patch(view, "/sims/test_ttt_2")
    assert html =~ "test_ttt_2"
    assert html =~ "Event Log"

    LemonSim.Store.delete_state("test_ttt_2")
  end
end
