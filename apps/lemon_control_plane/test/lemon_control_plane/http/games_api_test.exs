defmodule LemonControlPlane.HTTP.GamesAPITest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias LemonControlPlane.HTTP.Router

  setup do
    clear_table(:game_matches)
    clear_table(:game_match_events)
    clear_table(:game_agent_tokens)
    clear_table(:game_rate_limits)
    :ok
  end

  test "create match requires auth" do
    conn =
      conn(:post, "/v1/games/matches", Jason.encode!(%{"game_type" => "connect4"}))
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert conn.status == 401

    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "auth_required"
  end

  test "move endpoint returns 429 when move burst limit is exceeded" do
    token = issue_token("agent-rate", "owner-rate")

    create_conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "opponent" => %{"type" => "lemon_bot"}})
      )
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert create_conn.status == 201
    match_id = Jason.decode!(create_conn.resp_body)["match"]["id"]

    statuses =
      Enum.map(1..6, fn n ->
        move_conn =
          conn(
            :post,
            "/v1/games/matches/#{match_id}/moves",
            Jason.encode!(%{
              "move" => %{"kind" => "drop", "column" => 0},
              "idempotency_key" => "idem-#{n}"
            })
          )
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("content-type", "application/json")
          |> Router.call([])

        move_conn.status
      end)

    assert 429 in statuses
  end

  test "move endpoint reports idempotent replay on duplicate idempotency key" do
    token = issue_token("agent-idem", "owner-idem")

    create_conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "opponent" => %{"type" => "lemon_bot"}})
      )
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert create_conn.status == 201
    match_id = Jason.decode!(create_conn.resp_body)["match"]["id"]

    request_body =
      Jason.encode!(%{
        "move" => %{"kind" => "drop", "column" => 3},
        "idempotency_key" => "same-key"
      })

    first_move =
      conn(:post, "/v1/games/matches/#{match_id}/moves", request_body)
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    second_move =
      conn(:post, "/v1/games/matches/#{match_id}/moves", request_body)
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert first_move.status == 200
    assert second_move.status == 200

    first_body = Jason.decode!(first_move.resp_body)
    second_body = Jason.decode!(second_move.resp_body)

    assert first_body["idempotent_replay"] == false
    assert second_body["idempotent_replay"] == true
    assert second_body["accepted_event_seq"] == first_body["accepted_event_seq"]
  end

  test "get_match returns 403 for private match to spectator" do
    {:ok, match} =
      LemonGames.Matches.Service.create_match(
        %{"game_type" => "connect4", "visibility" => "private"},
        %{"agent_id" => "private-owner", "display_name" => "Owner"}
      )

    conn =
      conn(:get, "/v1/games/matches/#{match["id"]}")
      |> Router.call([])

    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "forbidden"
  end

  test "events endpoint redacts unresolved rps throws for other players" do
    token1 = issue_token("rps-agent-1", "owner-rps")
    token2 = issue_token("rps-agent-2", "owner-rps")

    create_conn =
      conn(:post, "/v1/games/matches", Jason.encode!(%{"game_type" => "rock_paper_scissors"}))
      |> put_req_header("authorization", "Bearer " <> token1)
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert create_conn.status == 201
    match_id = Jason.decode!(create_conn.resp_body)["match"]["id"]

    accept_conn =
      conn(:post, "/v1/games/matches/#{match_id}/accept", Jason.encode!(%{}))
      |> put_req_header("authorization", "Bearer " <> token2)
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert accept_conn.status == 200

    move_conn =
      conn(
        :post,
        "/v1/games/matches/#{match_id}/moves",
        Jason.encode!(%{
          "move" => %{"kind" => "throw", "value" => "rock"},
          "idempotency_key" => "rps-1"
        })
      )
      |> put_req_header("authorization", "Bearer " <> token1)
      |> put_req_header("content-type", "application/json")
      |> Router.call([])

    assert move_conn.status == 200

    events_conn =
      conn(:get, "/v1/games/matches/#{match_id}/events?after_seq=0&limit=50")
      |> put_req_header("authorization", "Bearer " <> token2)
      |> Router.call([])

    assert events_conn.status == 200
    body = Jason.decode!(events_conn.resp_body)
    move_event = Enum.find(body["events"], &(&1["event_type"] == "move_submitted"))
    assert get_in(move_event, ["payload", "move", "value"]) == "hidden"
  end

  defp issue_token(agent_id, owner_id) do
    {:ok, issued} =
      LemonGames.Auth.issue_token(%{
        "agent_id" => agent_id,
        "owner_id" => owner_id,
        "scopes" => ["games:play", "games:read"]
      })

    issued.token
  end

  defp clear_table(table) do
    table
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(table, key) end)
  end
end
