defmodule LemonSimUi.WerewolfPagesTest do
  use LemonSimUi.ConnCase

  alias LemonSim.Examples.Werewolf.League
  alias LemonSimUi.WerewolfArena

  @moduletag :tmp_dir

  defp with_league_dir(tmp_dir) do
    original = Application.get_env(:lemon_sim_ui, :werewolf_arena)
    Application.put_env(:lemon_sim_ui, :werewolf_arena, league_dir: tmp_dir)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:lemon_sim_ui, :werewolf_arena)
        value -> Application.put_env(:lemon_sim_ui, :werewolf_arena, value)
      end
    end)
  end

  defp record_sample_game(tmp_dir, game_id, winner) do
    world = %{
      status: "game_over",
      winner: winner,
      day_number: 3,
      players: %{
        "Aria" => %{role: "werewolf", model: "openai/gpt-x", status: "dead"},
        "Brin" => %{role: "seer", model: "anthropic/claude-x", status: "alive"},
        "Cole" => %{role: "doctor", model: "google/gemini-x", status: "alive"},
        "Dara" => %{role: "villager", model: "anthropic/claude-x", status: "alive"}
      },
      vote_history: [],
      night_history: []
    }

    record =
      League.game_record(world,
        game_id: game_id,
        recorded_at: "2026-07-06T00:00:00Z"
      )

    {:ok, _} = League.record_game!(tmp_dir, record)
  end

  describe "/werewolf" do
    test "shows the intermission page when no game is live", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/werewolf")

      assert html =~ "Werewolf Arena"
      assert html =~ "Intermission"
      assert html =~ "/werewolf/leaderboard"
    end
  end

  describe "/werewolf/leaderboard" do
    test "shows empty state without any recorded games", %{conn: conn, tmp_dir: tmp_dir} do
      with_league_dir(tmp_dir)

      {:ok, _view, html} = live(conn, "/werewolf/leaderboard")

      assert html =~ "Werewolf League"
      assert html =~ "No Games Recorded Yet"
    end

    test "renders standings, role specialists, and recent games", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      with_league_dir(tmp_dir)
      record_sample_game(tmp_dir, "ww_page1", "villagers")

      {:ok, _view, html} = live(conn, "/werewolf/leaderboard")

      assert html =~ "Overall Standings"
      assert html =~ "anthropic/claude-x"
      assert html =~ "openai/gpt-x"
      assert html =~ "Role Specialists"
      assert html =~ "Seer"
      assert html =~ "Recent Games"
      assert html =~ "ww_page1"
      assert html =~ "Village"
    end

    test "refreshes when the arena records a game", %{conn: conn, tmp_dir: tmp_dir} do
      with_league_dir(tmp_dir)

      {:ok, view, html} = live(conn, "/werewolf/leaderboard")
      assert html =~ "No Games Recorded Yet"

      record_sample_game(tmp_dir, "ww_page2", "werewolves")

      LemonCore.Bus.broadcast(
        WerewolfArena.league_topic(),
        LemonCore.Event.new(:werewolf_league_updated, %{game_id: "ww_page2"}, %{})
      )

      assert render_async_eventually(view, "ww_page2")
    end
  end

  describe "lobby hero" do
    test "features the werewolf arena with league links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Werewolf Arena"
      assert html =~ "Models play Werewolf, around the clock"
      assert html =~ "/werewolf/leaderboard"
    end
  end

  defp render_async_eventually(view, needle, attempts \\ 50)

  defp render_async_eventually(_view, needle, 0) do
    flunk("leaderboard never rendered #{inspect(needle)}")
  end

  defp render_async_eventually(view, needle, attempts) do
    html = render(view)

    if html =~ needle do
      true
    else
      Process.sleep(20)
      render_async_eventually(view, needle, attempts - 1)
    end
  end
end
