defmodule LemonWeb.Live.GamesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LemonCore.Event
  alias LemonGames.Matches.Service

  @endpoint LemonWeb.Endpoint

  @actor1 %{"agent_id" => "lv_actor_1", "display_name" => "LV Actor 1"}
  @actor2 %{"agent_id" => "lv_actor_2", "display_name" => "LV Actor 2"}

  setup do
    for table <- [:game_matches, :game_match_events, :game_agent_tokens, :game_rate_limits] do
      LemonCore.Store.list(table)
      |> Enum.each(fn {key, _} -> LemonCore.Store.delete(table, key) end)
    end

    :ok
  end

  test "GET /games renders lobby" do
    conn = get(build_conn(), "/games")
    assert html_response(conn, 200) =~ "Games Lobby"
  end

  test "lobby updates when lobby event is received" do
    {:ok, view, html} = live(build_conn(), "/games")
    assert html =~ "No active matches"

    {:ok, match} =
      Service.create_match(%{"game_type" => "connect4", "visibility" => "public"}, @actor1)

    send(view.pid, Event.new(:game_lobby_changed, %{}))

    assert render(view) =~ match["id"]
    assert render(view) =~ "Connect 4"
  end

  test "lobby updates on refresh tick without lobby bus event" do
    {:ok, view, html} = live(build_conn(), "/games")
    assert html =~ "No active matches"

    {:ok, match} =
      Service.create_match(%{"game_type" => "connect4", "visibility" => "public"}, @actor1)

    send(view.pid, :refresh_lobby)

    assert render(view) =~ match["id"]
  end

  test "GET /games/:match_id renders match details" do
    {:ok, match_id} = create_active_match()

    conn = get(build_conn(), "/games/#{match_id}")
    html = html_response(conn, 200)

    # Check that the match page renders with key elements
    assert html =~ "Turn #1"
    assert html =~ "connect4-board"
    assert html =~ "Back to lobby"
    assert html =~ "VS"
  end

  test "match live updates after game event" do
    {:ok, match_id} = create_active_match()
    {:ok, view, html} = live(build_conn(), "/games/#{match_id}")

    assert html =~ "Turn #1"

    assert {:ok, _updated, _seq, false} =
             Service.submit_move(
               match_id,
               @actor1,
               %{"kind" => "drop", "column" => 0},
               "lv-move-1"
             )

    send(view.pid, Event.new(:game_match_event, %{}))

    assert render(view) =~ "Turn #2"
  end

  test "match live updates on refresh tick without match bus event" do
    {:ok, match_id} = create_active_match()
    {:ok, view, html} = live(build_conn(), "/games/#{match_id}")

    assert html =~ "Turn #1"

    assert {:ok, _updated, _seq, false} =
             Service.submit_move(
               match_id,
               @actor1,
               %{"kind" => "drop", "column" => 0},
               "lv-move-2"
             )

    send(view.pid, :refresh_match)

    assert render(view) =~ "Turn #2"
  end

  test "match live catches up multiple missed events from event log cursor" do
    {:ok, match_id} = create_active_match()
    {:ok, view, html} = live(build_conn(), "/games/#{match_id}")

    assert html =~ "Turn #1"

    assert {:ok, _updated, _seq, false} =
             Service.submit_move(
               match_id,
               @actor1,
               %{"kind" => "drop", "column" => 0},
               "lv-move-catchup-1"
             )

    assert {:ok, _updated, _seq, false} =
             Service.submit_move(
               match_id,
               @actor2,
               %{"kind" => "drop", "column" => 1},
               "lv-move-catchup-2"
             )

    send(view.pid, :refresh_match)

    assert render(view) =~ "Turn #3"
  end

  test "unknown match shows not found message" do
    {:ok, _view, html} = live(build_conn(), "/games/nonexistent")
    assert html =~ "Match not found"
  end

  defp create_active_match do
    with {:ok, pending} <-
           Service.create_match(%{"game_type" => "connect4", "visibility" => "public"}, @actor1),
         {:ok, active} <- Service.accept_match(pending["id"], @actor2) do
      {:ok, active["id"]}
    end
  end
end
