defmodule LemonControlPlane.HTTP.GamesAPI do
  @moduledoc "REST API handler for the games platform."

  import Plug.Conn

  def call(conn, action) do
    apply(__MODULE__, action, [conn])
  end

  # GET /v1/games/lobby
  def lobby(conn) do
    matches = LemonGames.Matches.Service.list_lobby()
    json(conn, 200, %{"matches" => matches})
  end

  # GET /v1/games/matches/:id
  def get_match(conn) do
    match_id = conn.params["id"]
    viewer = viewer_from_conn(conn)

    case LemonGames.Matches.Service.get_match(match_id, viewer) do
      {:ok, match} -> json(conn, 200, %{"match" => match})
      {:error, :not_found, _} -> error(conn, 404, "not_found", "match not found")
    end
  end

  # GET /v1/games/matches/:id/events
  def list_events(conn) do
    match_id = conn.params["id"]
    after_seq = parse_int(conn.params["after_seq"], 0)
    limit = parse_int(conn.params["limit"], 50)

    case LemonGames.Matches.Service.list_events(match_id, after_seq, limit, "spectator") do
      {:ok, events, next_after_seq, has_more} ->
        json(conn, 200, %{"events" => events, "next_after_seq" => next_after_seq, "has_more" => has_more})
    end
  end

  # POST /v1/games/matches
  def create_match(conn) do
    with {:ok, actor} <- authenticate(conn, "games:play"),
         {:ok, body} <- parse_body(conn) do
      case LemonGames.Matches.Service.create_match(body, actor) do
        {:ok, match} ->
          viewer = %{"slot" => "p1", "agent_id" => actor["agent_id"]}
          json(conn, 201, %{"match" => LemonGames.Matches.Projection.project_public_view(match, "p1"), "viewer" => viewer})
        {:error, :unknown_game_type, msg} -> error(conn, 400, "unknown_game_type", msg)
        {:error, code, msg} -> error(conn, 422, to_string(code), msg)
      end
    end
  end

  # POST /v1/games/matches/:id/accept
  def accept_match(conn) do
    with {:ok, actor} <- authenticate(conn, "games:play"),
         match_id = conn.params["id"] do
      case LemonGames.Matches.Service.accept_match(match_id, actor) do
        {:ok, match} ->
          json(conn, 200, %{"match" => LemonGames.Matches.Projection.project_public_view(match, "p2")})
        {:error, :not_found, msg} -> error(conn, 404, "not_found", msg)
        {:error, :invalid_state, msg} -> error(conn, 409, "invalid_state", msg)
        {:error, :already_joined, msg} -> error(conn, 409, "already_joined", msg)
        {:error, code, msg} -> error(conn, 422, to_string(code), msg)
      end
    end
  end

  # POST /v1/games/matches/:id/moves
  def submit_move(conn) do
    with {:ok, actor} <- authenticate(conn, "games:play"),
         {:ok, body} <- parse_body(conn),
         {:ok, _} <- check_rate_limit(conn, actor, conn.params["id"]) do
      match_id = conn.params["id"]
      move = body["move"]
      idempotency_key = body["idempotency_key"]

      unless idempotency_key do
        error(conn, 400, "missing_param", "idempotency_key is required")
      else
        case LemonGames.Matches.Service.submit_move(match_id, actor, move, idempotency_key) do
          {:ok, match, seq} ->
            json(conn, 200, %{
              "match" => LemonGames.Matches.Projection.project_public_view(match, actor_slot(match, actor)),
              "accepted_event_seq" => seq,
              "idempotent_replay" => false
            })
          {:error, :not_found, msg} -> error(conn, 404, "not_found", msg)
          {:error, :wrong_turn, msg} -> error(conn, 409, "wrong_turn", msg)
          {:error, :invalid_state, msg} -> error(conn, 409, "invalid_state", msg)
          {:error, :not_player, msg} -> error(conn, 403, "not_player", msg)
          {:error, :illegal_move, msg} -> error(conn, 422, "illegal_move", msg)
          {:error, code, msg} -> error(conn, 422, to_string(code), msg)
        end
      end
    end
  end

  # --- Helpers ---

  defp authenticate(conn, required_scope) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case LemonGames.Auth.validate_token(token) do
          {:ok, claims} ->
            if LemonGames.Auth.has_scope?(claims, required_scope) do
              {:ok, %{"agent_id" => claims["agent_id"], "owner_id" => claims["owner_id"], "scopes" => claims["scopes"]}}
            else
              error(conn, 403, "insufficient_scope", "requires #{required_scope}")
            end
          {:error, reason} ->
            error(conn, 401, "auth_failed", to_string(reason))
        end
      _ ->
        error(conn, 401, "auth_required", "Bearer token required")
    end
  end

  defp check_rate_limit(_conn, actor, match_id) do
    # Use agent_id as the rate limit key
    token_key = actor["agent_id"]
    case LemonGames.RateLimit.check_move(token_key, match_id) do
      :ok -> {:ok, :allowed}
      {:error, :rate_limited, retry_after} ->
        # Return the error directly since we want a specific format
        {:error, :rate_limited, retry_after}
    end
  end

  defp parse_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> {:ok, %{}}
      params when is_map(params) -> {:ok, params}
    end
  end

  defp viewer_from_conn(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case LemonGames.Auth.validate_token(token) do
          {:ok, claims} -> claims["agent_id"]
          _ -> "spectator"
        end
      _ -> "spectator"
    end
  end

  defp actor_slot(match, actor) do
    case Enum.find(match["players"] || %{}, fn {_, p} -> p["agent_id"] == actor["agent_id"] end) do
      {slot, _} -> slot
      nil -> "spectator"
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp error(conn, status, code, message) do
    json(conn, status, %{"error" => %{"code" => code, "message" => message}})
  end
end
