defmodule LemonWeb.Live.GamesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias LemonGames.Matches.Service

  @endpoint LemonWeb.Endpoint

  @actor %{"agent_id" => "web_test_agent", "display_name" => "Web Tester"}

  test "lobby page renders public match" do
    {:ok, match} =
      Service.create_match(
        %{
          "game_type" => "connect4",
          "opponent" => %{"type" => "lemon_bot"},
          "visibility" => "public"
        },
        @actor
      )

    {:ok, _view, html} = live(build_conn(), "/games")

    assert html =~ "Live Lobby"
    assert html =~ match["id"]
    assert html =~ "Web Tester vs Lemon Bot"
  end

  test "match page renders not found state" do
    {:ok, _view, html} = live(build_conn(), "/games/missing-match")
    assert html =~ "Match not found"
  end

  test "match page renders existing connect4 match" do
    {:ok, match} =
      Service.create_match(
        %{
          "game_type" => "connect4",
          "opponent" => %{"type" => "lemon_bot"},
          "visibility" => "public"
        },
        @actor
      )

    {:ok, _view, html} = live(build_conn(), "/games/#{match["id"]}")

    assert html =~ "Game State"
    assert html =~ "Connect4"
    assert html =~ match["id"]
    assert html =~ "Players"
    assert html =~ "Lemon Bot"
    assert html =~ "Move History"
  end
end
