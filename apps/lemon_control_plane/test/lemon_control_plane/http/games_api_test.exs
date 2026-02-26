defmodule LemonControlPlane.HTTP.GamesAPITest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias LemonControlPlane.HTTP.Router

  @actor1 %{
    "agent_id" => "games_api_actor_1",
    "owner_id" => "owner_1",
    "scopes" => ["games:play", "games:read"]
  }
  @actor2 %{
    "agent_id" => "games_api_actor_2",
    "owner_id" => "owner_2",
    "scopes" => ["games:play", "games:read"]
  }
  @read_only_actor %{
    "agent_id" => "games_api_read_only",
    "owner_id" => "owner_ro",
    "scopes" => ["games:read"]
  }

  setup do
    for table <- [:game_matches, :game_match_events, :game_agent_tokens, :game_rate_limits] do
      LemonCore.Store.list(table)
      |> Enum.each(fn {key, _} -> LemonCore.Store.delete(table, key) end)
    end

    {:ok, token1} = issue_token(@actor1)
    {:ok, token2} = issue_token(@actor2)

    {:ok, %{token1: token1, token2: token2}}
  end

  test "create_match returns 403 when token lacks games:play scope" do
    {:ok, read_only_token} = issue_token(@read_only_actor)

    conn =
      post_json(
        "/v1/games/matches",
        %{"game_type" => "connect4", "visibility" => "public"},
        read_only_token
      )

    assert conn.status == 403

    assert %{
             "error" => %{
               "code" => "insufficient_scope",
               "message" => "requires games:play"
             }
           } = decode(conn)
  end

  test "get_match returns 401 when bearer token contains internal whitespace" do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> put_req_header("authorization", "Bearer token with-space")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "create_match returns 401 when bearer token contains internal whitespace" do
    conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "visibility" => "public"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer token with-space")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "create_match returns 401 when bearer token contains tab whitespace" do
    conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "visibility" => "public"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer token\twith-tab")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "create_match accepts lowercase bearer auth scheme", %{token1: token1} do
    conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "visibility" => "public"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "bearer " <> token1)
      |> Router.call([])

    assert conn.status == 201
    assert %{"match" => %{"game_type" => "connect4"}} = decode(conn)
  end

  test "create_match accepts bearer auth scheme with multiple spaces before token", %{token1: token1} do
    conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "visibility" => "public"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer   " <> token1)
      |> Router.call([])

    assert conn.status == 201
    assert %{"match" => %{"game_type" => "connect4"}} = decode(conn)
  end

  test "create_match accepts mixed-case bearer auth scheme", %{token1: token1} do
    conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "visibility" => "public"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "BeArEr " <> token1)
      |> Router.call([])

    assert conn.status == 201
    assert %{"match" => %{"game_type" => "connect4"}} = decode(conn)
  end

  test "get_match accepts uppercase bearer auth scheme", %{token1: token1} do
    {:ok, match_id} = create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> put_req_header("authorization", "BEARER " <> token1)
      |> Router.call([])

    assert conn.status == 200
    assert %{"match" => %{"id" => ^match_id}} = decode(conn)
  end

  test "list_events accepts mixed-case bearer auth scheme", %{token1: token1} do
    {:ok, match_id} = create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}/events?after_seq=0&limit=20")
      |> put_req_header("authorization", "bEaReR " <> token1)
      |> Router.call([])

    assert conn.status == 200
    assert %{"events" => events} = decode(conn)
    assert is_list(events)
  end

  test "get_match accepts bearer auth scheme with multiple spaces before token", %{token1: token1} do
    {:ok, match_id} = create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> put_req_header("authorization", "bearer  " <> token1)
      |> Router.call([])

    assert conn.status == 200
    assert %{"match" => %{"id" => ^match_id}} = decode(conn)
  end

  test "create_match returns 401 when multiple authorization headers are present" do
    conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "visibility" => "public"})
      )
      |> put_req_header("content-type", "application/json")
      |> then(fn conn ->
        %{conn | req_headers: [{"authorization", "Bearer token-one"}, {"authorization", "Bearer token-two"} | conn.req_headers]}
      end)
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "get_match returns 401 when authorization header contains comma-delimited bearer tokens" do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> put_req_header("authorization", "Bearer token-one, Bearer token-two")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "submit_move returns 403 when token lacks games:play scope" do
    {:ok, read_only_token} = issue_token(@read_only_actor)
    {:ok, match_id} = create_active_match(@read_only_actor, @actor2)

    conn =
      post_json(
        "/v1/games/matches/#{match_id}/moves",
        %{"move" => %{"kind" => "drop", "column" => 0}, "idempotency_key" => "scope-check"},
        read_only_token
      )

    assert conn.status == 403

    assert %{
             "error" => %{
               "code" => "insufficient_scope",
               "message" => "requires games:play"
             }
           } = decode(conn)
  end

  test "submit_move returns 400 when idempotency_key is missing", %{token1: token1} do
    {:ok, match_id} = create_active_match(@actor1, @actor2)

    conn =
      conn(
        :post,
        "/v1/games/matches/#{match_id}/moves",
        Jason.encode!(%{"move" => %{"kind" => "drop", "column" => 0}})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert conn.status == 400
    assert %{"error" => %{"code" => "missing_param"}} = decode(conn)
  end

  test "submit_move returns 400 when move is missing", %{token1: token1} do
    {:ok, match_id} = create_active_match(@actor1, @actor2)

    conn =
      conn(
        :post,
        "/v1/games/matches/#{match_id}/moves",
        Jason.encode!(%{"idempotency_key" => "missing-move"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert conn.status == 400

    assert %{"error" => %{"code" => "missing_param", "message" => "move is required"}} =
             decode(conn)
  end

  test "create_match returns 401 when bearer token is invalid" do
    conn =
      post_json(
        "/v1/games/matches",
        %{"game_type" => "connect4", "visibility" => "public"},
        "invalid-token"
      )

    assert conn.status == 401
    assert %{"error" => %{"code" => "auth_failed"}} = decode(conn)
  end

  test "create_match returns 401 when authorization header is non-bearer" do
    conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "visibility" => "public"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Basic not-a-bearer")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "create_match returns 401 when authorization header contains comma-delimited bearer tokens" do
    conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "visibility" => "public"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer token-one, Bearer token-two")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "create_match returns 401 when bearer token has leading/trailing whitespace" do
    conn =
      conn(
        :post,
        "/v1/games/matches",
        Jason.encode!(%{"game_type" => "connect4", "visibility" => "public"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer   token-with-spaces   ")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "submit_move returns 400 when request body is not a JSON object", %{token1: token1} do
    {:ok, match_id} = create_active_match(@actor1, @actor2)

    conn =
      conn(
        :post,
        "/v1/games/matches/#{match_id}/moves",
        Jason.encode!([%{"move" => %{"kind" => "drop", "column" => 0}}])
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert conn.status == 400

    assert %{
             "error" => %{
               "code" => "invalid_param",
               "message" => "request body must be a JSON object"
             }
           } = decode(conn)
  end

  test "submit_move returns 400 when idempotency_key is blank", %{token1: token1} do
    {:ok, match_id} = create_active_match(@actor1, @actor2)

    conn =
      conn(
        :post,
        "/v1/games/matches/#{match_id}/moves",
        Jason.encode!(%{"move" => %{"kind" => "drop", "column" => 0}, "idempotency_key" => "   "})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert conn.status == 400

    assert %{
             "error" => %{
               "code" => "invalid_param",
               "message" => "idempotency_key must be a non-empty string"
             }
           } = decode(conn)
  end

  test "submit_move returns 429 and retry-after header when rate limited", %{token1: token1} do
    {:ok, match_id} = create_active_match(@actor1, @actor2)

    for i <- 1..4 do
      conn =
        conn(
          :post,
          "/v1/games/matches/#{match_id}/moves",
          Jason.encode!(%{
            "move" => %{"kind" => "drop", "column" => 0},
            "idempotency_key" => "rl-ok-#{i}"
          })
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer " <> token1)
        |> Router.call([])

      assert conn.status in [200, 409]
    end

    limited =
      conn(
        :post,
        "/v1/games/matches/#{match_id}/moves",
        Jason.encode!(%{
          "move" => %{"kind" => "drop", "column" => 0},
          "idempotency_key" => "rl-hit"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert limited.status == 429
    assert get_resp_header(limited, "retry-after") != []
    assert %{"error" => %{"code" => "rate_limited"}} = decode(limited)
  end

  test "submit_move returns 409 for idempotency key conflict across actors", %{
    token1: token1,
    token2: token2
  } do
    {:ok, match_id} = create_active_match(@actor1, @actor2)

    first =
      conn(
        :post,
        "/v1/games/matches/#{match_id}/moves",
        Jason.encode!(%{
          "move" => %{"kind" => "drop", "column" => 0},
          "idempotency_key" => "shared-key"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert first.status == 200

    conflict =
      conn(
        :post,
        "/v1/games/matches/#{match_id}/moves",
        Jason.encode!(%{
          "move" => %{"kind" => "drop", "column" => 0},
          "idempotency_key" => "shared-key"
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token2)
      |> Router.call([])

    assert conflict.status == 409
    assert %{"error" => %{"code" => "idempotency_conflict"}} = decode(conflict)
  end

  test "create_match returns 400 for unsupported visibility", %{token1: token1} do
    conn =
      post_json(
        "/v1/games/matches",
        %{"game_type" => "connect4", "visibility" => "friends_only"},
        token1
      )

    assert conn.status == 400
    assert %{"error" => %{"code" => "invalid_visibility"}} = decode(conn)
  end

  test "create_match returns 400 when game_type is missing", %{token1: token1} do
    conn = post_json("/v1/games/matches", %{"visibility" => "public"}, token1)

    assert conn.status == 400

    assert %{"error" => %{"code" => "missing_param", "message" => "game_type is required"}} =
             decode(conn)
  end

  test "create_match returns 400 when game_type is blank", %{token1: token1} do
    conn = post_json("/v1/games/matches", %{"game_type" => "   "}, token1)

    assert conn.status == 400

    assert %{
             "error" => %{
               "code" => "invalid_param",
               "message" => "game_type must be a non-empty string"
             }
           } = decode(conn)
  end

  test "create_match returns 400 when request body is not a JSON object", %{token1: token1} do
    conn =
      conn(:post, "/v1/games/matches", Jason.encode!([%{"game_type" => "connect4"}]))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert conn.status == 400

    assert %{
             "error" => %{
               "code" => "invalid_param",
               "message" => "request body must be a JSON object"
             }
           } = decode(conn)
  end

  test "submit_move returns idempotent_replay=true on safe retry", %{token1: token1} do
    {:ok, match_id} = create_active_match(@actor1, @actor2)

    first =
      post_json(
        "/v1/games/matches/#{match_id}/moves",
        %{"move" => %{"kind" => "drop", "column" => 0}, "idempotency_key" => "idem-replay"},
        token1
      )

    assert first.status == 200
    assert %{"idempotent_replay" => false, "accepted_event_seq" => seq} = decode(first)

    replay =
      post_json(
        "/v1/games/matches/#{match_id}/moves",
        %{"move" => %{"kind" => "drop", "column" => 0}, "idempotency_key" => "idem-replay"},
        token1
      )

    assert replay.status == 200
    assert %{"idempotent_replay" => true, "accepted_event_seq" => ^seq} = decode(replay)
  end

  test "external agents can finish a full connect4 match over REST", %{
    token1: token1,
    token2: token2
  } do
    create =
      post_json(
        "/v1/games/matches",
        %{"game_type" => "connect4", "visibility" => "public"},
        token1
      )

    assert create.status == 201
    %{"match" => %{"id" => match_id, "status" => "pending_accept"}} = decode(create)

    accept = post_json("/v1/games/matches/#{match_id}/accept", %{}, token2)
    assert accept.status == 200

    assert_move(match_id, token1, %{"kind" => "drop", "column" => 0}, "c4-p1-1")
    assert_move(match_id, token2, %{"kind" => "drop", "column" => 1}, "c4-p2-1")
    assert_move(match_id, token1, %{"kind" => "drop", "column" => 0}, "c4-p1-2")
    assert_move(match_id, token2, %{"kind" => "drop", "column" => 1}, "c4-p2-2")
    assert_move(match_id, token1, %{"kind" => "drop", "column" => 0}, "c4-p1-3")
    assert_move(match_id, token2, %{"kind" => "drop", "column" => 1}, "c4-p2-3")

    final = assert_move(match_id, token1, %{"kind" => "drop", "column" => 0}, "c4-p1-4")

    assert final["match"]["status"] == "finished"
    assert final["match"]["result"]["winner"] == "p1"
  end

  test "private match is not visible to spectators", %{token1: token1} do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "private"})

    spectator_get =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> Router.call([])

    assert spectator_get.status == 404
    assert %{"error" => %{"code" => "not_found"}} = decode(spectator_get)

    owner_get =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert owner_get.status == 200
    assert %{"match" => %{"id" => ^match_id, "visibility" => "private"}} = decode(owner_get)
  end

  test "get_match returns 401 when bearer token is invalid" do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> put_req_header("authorization", "Bearer invalid-token")
      |> Router.call([])

    assert conn.status == 401
    assert %{"error" => %{"code" => "auth_failed"}} = decode(conn)
  end

  test "get_match returns 401 when authorization header is non-bearer" do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> put_req_header("authorization", "Basic not-a-bearer")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "list_events returns 401 when authorization header is blank bearer" do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}/events?after_seq=0&limit=20")
      |> put_req_header("authorization", "Bearer    ")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "get_match returns 401 when authorization header is blank bearer" do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> put_req_header("authorization", "Bearer   ")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "get_match returns 401 when bearer token has leading/trailing whitespace" do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}")
      |> put_req_header("authorization", "Bearer   token-with-spaces   ")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "private match events are not visible to spectators", %{token1: token1} do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "private"})

    spectator_events =
      conn(:get, "/v1/games/matches/#{match_id}/events?after_seq=0&limit=20")
      |> Router.call([])

    assert spectator_events.status == 404
    assert %{"error" => %{"code" => "not_found"}} = decode(spectator_events)

    owner_events =
      conn(:get, "/v1/games/matches/#{match_id}/events?after_seq=0&limit=20")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert owner_events.status == 200
    assert %{"events" => events} = decode(owner_events)
    assert is_list(events)
  end

  test "list_events returns 400 for invalid pagination params", %{token1: token1} do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    bad_after_seq =
      conn(:get, "/v1/games/matches/#{match_id}/events?after_seq=-1")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert bad_after_seq.status == 400
    assert %{"error" => %{"code" => "invalid_param"}} = decode(bad_after_seq)

    bad_limit =
      conn(:get, "/v1/games/matches/#{match_id}/events?limit=0")
      |> put_req_header("authorization", "Bearer " <> token1)
      |> Router.call([])

    assert bad_limit.status == 400
    assert %{"error" => %{"code" => "invalid_param"}} = decode(bad_limit)
  end

  test "list_events returns 401 when bearer token is invalid" do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}/events?after_seq=0&limit=20")
      |> put_req_header("authorization", "Bearer invalid-token")
      |> Router.call([])

    assert conn.status == 401
    assert %{"error" => %{"code" => "auth_failed"}} = decode(conn)
  end

  test "list_events returns 401 when authorization header is non-bearer" do
    {:ok, match_id} =
      create_match(@actor1, %{"game_type" => "connect4", "visibility" => "public"})

    conn =
      conn(:get, "/v1/games/matches/#{match_id}/events?after_seq=0&limit=20")
      |> put_req_header("authorization", "Token not-a-bearer")
      |> Router.call([])

    assert conn.status == 401

    assert %{
             "error" => %{
               "code" => "auth_required",
               "message" => "Bearer token required"
             }
           } = decode(conn)
  end

  test "external agents can finish a full rock-paper-scissors match over REST", %{
    token1: token1,
    token2: token2
  } do
    create =
      post_json(
        "/v1/games/matches",
        %{"game_type" => "rock_paper_scissors", "visibility" => "public"},
        token1
      )

    assert create.status == 201
    %{"match" => %{"id" => match_id, "status" => "pending_accept"}} = decode(create)

    accept = post_json("/v1/games/matches/#{match_id}/accept", %{}, token2)
    assert accept.status == 200

    p1_turn =
      assert_move(match_id, token1, %{"kind" => "throw", "value" => "rock"}, "rps-p1-1")

    assert p1_turn["match"]["status"] == "active"
    assert p1_turn["match"]["game_state"]["resolved"] == false
    assert p1_turn["match"]["game_state"]["throws"] == %{}

    final =
      assert_move(match_id, token2, %{"kind" => "throw", "value" => "scissors"}, "rps-p2-1")

    assert final["match"]["status"] == "finished"
    assert final["match"]["result"]["winner"] == "p1"
  end

  defp create_active_match(actor1, actor2) do
    with {:ok, pending} <-
           LemonGames.Matches.Service.create_match(
             %{"game_type" => "connect4", "visibility" => "public"},
             actor1
           ),
         {:ok, active} <- LemonGames.Matches.Service.accept_match(pending["id"], actor2) do
      {:ok, active["id"]}
    end
  end

  defp create_match(actor, params) do
    with {:ok, match} <- LemonGames.Matches.Service.create_match(params, actor) do
      {:ok, match["id"]}
    end
  end

  defp issue_token(actor) do
    LemonGames.Auth.issue_token(%{
      "agent_id" => actor["agent_id"],
      "owner_id" => actor["owner_id"],
      "scopes" => actor["scopes"]
    })
    |> case do
      {:ok, result} -> {:ok, result.token}
      error -> error
    end
  end

  defp assert_move(match_id, token, move, idem) do
    response =
      post_json(
        "/v1/games/matches/#{match_id}/moves",
        %{"move" => move, "idempotency_key" => idem},
        token
      )

    assert response.status == 200
    decode(response)
  end

  defp post_json(path, body, token) do
    conn =
      conn(:post, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn =
      if is_binary(token) do
        put_req_header(conn, "authorization", "Bearer " <> token)
      else
        conn
      end

    Router.call(conn, [])
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)
end
