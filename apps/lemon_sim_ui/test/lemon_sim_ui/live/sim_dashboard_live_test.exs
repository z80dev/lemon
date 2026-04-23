defmodule LemonSimUi.SimDashboardLiveTest do
  use LemonSimUi.ConnCase

  import Phoenix.LiveViewTest

  test "mounts with no sims", %{conn: conn} do
    {:ok, view, html} = live(conn, "/admin")
    assert html =~ "LemonSim"
    assert html =~ "SYSTEM STANDBY"
    assert render(view) =~ "0 active"
  end

  test "shows sim list when sims exist", %{conn: conn} do
    state =
      LemonSim.State.new(
        sim_id: "test_ttt_1",
        world: LemonSim.Examples.TicTacToe.initial_world()
      )

    LemonSim.Store.put_state(state)
    on_exit(fn -> LemonSim.Store.delete_state("test_ttt_1") end)

    {:ok, _view, html} = live(conn, "/admin")
    assert html =~ "test_ttt_1"
    assert html =~ "Tic Tac Toe"
  end

  test "navigates to sim detail", %{conn: conn} do
    state =
      LemonSim.State.new(
        sim_id: "test_ttt_2",
        world: LemonSim.Examples.TicTacToe.initial_world()
      )

    LemonSim.Store.put_state(state)
    on_exit(fn -> LemonSim.Store.delete_state("test_ttt_2") end)

    {:ok, view, _html} = live(conn, "/admin")
    html = render_patch(view, "/admin/sims/test_ttt_2")
    assert html =~ "test_ttt_2"
    assert html =~ "telemetry packets"
  end

  test "werewolf launch form exposes Z.ai GLM-5 in model assignments", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin")

    view
    |> element("aside button[phx-click=\"toggle_new_sim_form\"]")
    |> render_click()

    html =
      view
      |> form("#new-sim-form", %{"domain" => "werewolf"})
      |> render_change()

    assert html =~ ~s(value="zai")

    html =
      view
      |> form("#new-sim-form", %{"domain" => "werewolf", "provider_1" => "zai"})
      |> render_change()

    assert html =~ "GLM-5"
    assert html =~ ~s(value="glm-5")
  end
end
