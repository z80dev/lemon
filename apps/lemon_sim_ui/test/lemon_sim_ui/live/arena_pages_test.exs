defmodule LemonSimUi.ArenaPagesTest do
  use LemonSimUi.ConnCase

  alias LemonSim.Bench.League
  alias LemonSimUi.Arena

  @moduletag :tmp_dir

  defp with_league_dir(domain, tmp_dir) do
    original = Application.get_env(:lemon_sim_ui, :arenas)
    Application.put_env(:lemon_sim_ui, :arenas, [{domain, [league_dir: tmp_dir]}])

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:lemon_sim_ui, :arenas)
        value -> Application.put_env(:lemon_sim_ui, :arenas, value)
      end
    end)
  end

  defp record_space_station_game(tmp_dir, game_id) do
    world = %{
      status: "game_over",
      winner: "crew",
      round: 4,
      players: %{
        "player_1" => %{role: "saboteur", model: "openai/gpt-x", status: "ejected"},
        "player_2" => %{role: "engineer", model: "zai/glm-5", status: "alive"},
        "player_3" => %{role: "crew", model: "anthropic/claude-x", status: "alive"}
      },
      action_history: [
        %{round: 1, actions: %{"player_1" => %{action: "fake_repair"}}}
      ],
      vote_history: []
    }

    record =
      League.game_record(LemonSim.Examples.SpaceStation.League, world,
        game_id: game_id,
        recorded_at: "2026-07-06T00:00:00Z"
      )

    {:ok, _} = League.record_game!(tmp_dir, record)
  end

  defp record_stock_market_game(tmp_dir, game_id) do
    world = %{
      status: "game_over",
      winner: "player_1",
      round: 10,
      players: %{
        "player_1" => %{name: "Ava", model: "anthropic/claude-x", cash: 2000, holdings: %{}},
        "player_2" => %{name: "Bo", model: "zai/glm-5", cash: 900, holdings: %{}}
      },
      stocks: %{},
      market_call_history: [],
      round_summaries: [],
      whisper_history: []
    }

    record =
      League.game_record(LemonSim.Examples.StockMarket.League, world,
        game_id: game_id,
        recorded_at: "2026-07-06T00:00:00Z"
      )

    {:ok, _} = League.record_game!(tmp_dir, record)
  end

  describe "/arena/:domain" do
    test "shows the intermission page when no game is live", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arena/space_station")

      assert html =~ "Space Station Crisis Arena"
      assert html =~ "Intermission"
      assert html =~ "/arena/space_station/leaderboard"
    end

    test "rejects unknown domains", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/arena/frisbee")
    end
  end

  describe "legacy werewolf routes" do
    test "redirect to the arena routes", %{conn: conn} do
      assert redirected_to(get(conn, "/werewolf")) == "/arena/werewolf"
      assert redirected_to(get(conn, "/werewolf/leaderboard")) == "/arena/werewolf/leaderboard"
    end
  end

  describe "/arena/:domain/leaderboard" do
    test "shows empty state without any recorded games", %{conn: conn, tmp_dir: tmp_dir} do
      with_league_dir(:space_station, tmp_dir)

      {:ok, _view, html} = live(conn, "/arena/space_station/leaderboard")

      assert html =~ "Space Station Crisis League"
      assert html =~ "No Games Recorded Yet"
    end

    test "renders team standings with role specialists", %{conn: conn, tmp_dir: tmp_dir} do
      with_league_dir(:space_station, tmp_dir)
      record_space_station_game(tmp_dir, "spc_page1")

      {:ok, _view, html} = live(conn, "/arena/space_station/leaderboard")

      assert html =~ "Overall Standings"
      assert html =~ "zai/glm-5"
      assert html =~ "Role Specialists"
      assert html =~ "Saboteur"
      assert html =~ "Recent Games"
      assert html =~ "spc_page1"
      assert html =~ "Crew"
    end

    test "renders ranked standings with mean value and stat leaders", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      with_league_dir(:stock_market, tmp_dir)
      record_stock_market_game(tmp_dir, "stk_page1")

      {:ok, _view, html} = live(conn, "/arena/stock_market/leaderboard")

      assert html =~ "Stock Market Arena League"
      assert html =~ "Mean value"
      assert html =~ "anthropic/claude-x"
      refute html =~ "Role Specialists"
      assert html =~ "Stat Leaders"
    end

    test "refreshes when the arena records a game", %{conn: conn, tmp_dir: tmp_dir} do
      with_league_dir(:space_station, tmp_dir)

      {:ok, view, html} = live(conn, "/arena/space_station/leaderboard")
      assert html =~ "No Games Recorded Yet"

      record_space_station_game(tmp_dir, "spc_page2")

      LemonCore.Bus.broadcast(
        Arena.league_topic(:space_station),
        LemonCore.Event.new(:arena_league_updated, %{game_id: "spc_page2"}, %{
          domain: :space_station
        })
      )

      assert render_eventually(view, "spc_page2")
    end
  end

  describe "lobby" do
    test "features all four arenas with watch and league links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Model Arenas"
      assert html =~ "Werewolf"
      assert html =~ "Space Station Crisis"
      assert html =~ "Stock Market Arena"
      assert html =~ "Survivor"
      assert html =~ "/arena/stock_market/leaderboard"
    end
  end

  defp render_eventually(view, needle, attempts \\ 50)

  defp render_eventually(_view, needle, 0) do
    flunk("leaderboard never rendered #{inspect(needle)}")
  end

  defp render_eventually(view, needle, attempts) do
    html = render(view)

    if html =~ needle do
      true
    else
      Process.sleep(20)
      render_eventually(view, needle, attempts - 1)
    end
  end
end
