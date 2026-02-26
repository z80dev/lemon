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
    with {:ok, viewer} <- viewer_from_conn(conn) do
      match_id = conn.params["id"]

      case LemonGames.Matches.Service.get_match(match_id, viewer) do
        {:ok, match} -> json(conn, 200, %{"match" => match})
        {:error, :not_found, _} -> error(conn, 404, "not_found", "match not found")
      end
    else
      %Plug.Conn{} = halted_conn ->
        halted_conn
    end
  end

  # GET /v1/games/matches/:id/events
  def list_events(conn) do
    with {:ok, viewer} <- viewer_from_conn(conn),
         {:ok, after_seq} <- parse_non_neg_int_param(conn.params["after_seq"], 0),
         {:ok, limit} <- parse_limit_param(conn.params["limit"], 50) do
      match_id = conn.params["id"]

      case LemonGames.Matches.Service.list_events(match_id, after_seq, limit, viewer) do
        {:ok, events, next_after_seq, has_more} ->
          json(conn, 200, %{
            "events" => events,
            "next_after_seq" => next_after_seq,
            "has_more" => has_more
          })

        {:error, :not_found, _} ->
          error(conn, 404, "not_found", "match not found")
      end
    else
      {:error, :invalid_param, msg} -> error(conn, 400, "invalid_param", msg)
      %Plug.Conn{} = halted_conn -> halted_conn
    end
  end

  # POST /v1/games/matches
  def create_match(conn) do
    with {:ok, actor} <- authenticate(conn, "games:play"),
         {:ok, body} <- parse_body(conn),
         {:ok, game_type} <- parse_game_type_param(body["game_type"]) do
      params = Map.put(body, "game_type", game_type)

      case LemonGames.Matches.Service.create_match(params, actor) do
        {:ok, match} ->
          viewer = %{"slot" => "p1", "agent_id" => actor["agent_id"]}

          json(conn, 201, %{
            "match" => LemonGames.Matches.Projection.project_public_view(match, "p1"),
            "viewer" => viewer
          })

        {:error, :unknown_game_type, msg} ->
          error(conn, 400, "unknown_game_type", msg)

        {:error, :invalid_visibility, msg} ->
          error(conn, 400, "invalid_visibility", msg)

        {:error, code, msg} ->
          error(conn, 422, to_string(code), msg)
      end
    else
      {:error, :missing_param, msg} ->
        error(conn, 400, "missing_param", msg)

      {:error, :invalid_param, msg} ->
        error(conn, 400, "invalid_param", msg)

      %Plug.Conn{} = halted_conn ->
        halted_conn
    end
  end

  # POST /v1/games/matches/:id/accept
  def accept_match(conn) do
    with {:ok, actor} <- authenticate(conn, "games:play"),
         match_id = conn.params["id"] do
      case LemonGames.Matches.Service.accept_match(match_id, actor) do
        {:ok, match} ->
          json(conn, 200, %{
            "match" => LemonGames.Matches.Projection.project_public_view(match, "p2")
          })

        {:error, :not_found, msg} ->
          error(conn, 404, "not_found", msg)

        {:error, :invalid_state, msg} ->
          error(conn, 409, "invalid_state", msg)

        {:error, :already_joined, msg} ->
          error(conn, 409, "already_joined", msg)

        {:error, code, msg} ->
          error(conn, 422, to_string(code), msg)
      end
    else
      %Plug.Conn{} = halted_conn ->
        halted_conn
    end
  end

  # POST /v1/games/matches/:id/moves
  def submit_move(conn) do
    with {:ok, actor} <- authenticate(conn, "games:play"),
         {:ok, body} <- parse_body(conn),
         {:ok, move} <- parse_move_param(body["move"]),
         {:ok, idempotency_key} <- parse_idempotency_key_param(body["idempotency_key"]),
         {:ok, _} <- check_rate_limit(conn, actor, conn.params["id"]) do
      match_id = conn.params["id"]

      case LemonGames.Matches.Service.submit_move(match_id, actor, move, idempotency_key) do
        {:ok, match, seq, replay?} ->
          json(conn, 200, %{
            "match" =>
              LemonGames.Matches.Projection.project_public_view(match, actor_slot(match, actor)),
            "accepted_event_seq" => seq,
            "idempotent_replay" => replay?
          })

        {:error, :not_found, msg} ->
          error(conn, 404, "not_found", msg)

        {:error, :wrong_turn, msg} ->
          error(conn, 409, "wrong_turn", msg)

        {:error, :invalid_state, msg} ->
          error(conn, 409, "invalid_state", msg)

        {:error, :idempotency_conflict, msg} ->
          error(conn, 409, "idempotency_conflict", msg)

        {:error, :not_player, msg} ->
          error(conn, 403, "not_player", msg)

        {:error, :illegal_move, msg} ->
          error(conn, 422, "illegal_move", msg)

        {:error, code, msg} ->
          error(conn, 422, to_string(code), msg)
      end
    else
      {:error, :missing_param, msg} ->
        error(conn, 400, "missing_param", msg)

      {:error, :invalid_param, msg} ->
        error(conn, 400, "invalid_param", msg)

      {:error, :rate_limited, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> error(429, "rate_limited", "rate limit exceeded")

      %Plug.Conn{} = halted_conn ->
        halted_conn
    end
  end

  # --- Helpers ---

  defp authenticate(conn, required_scope) do
    case authorization_header(conn) do
      {:bearer, token} ->
        case LemonGames.Auth.validate_token(token) do
          {:ok, claims} ->
            if LemonGames.Auth.has_scope?(claims, required_scope) do
              {:ok,
               %{
                 "agent_id" => claims["agent_id"],
                 "owner_id" => claims["owner_id"],
                 "scopes" => claims["scopes"]
               }}
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
      :ok ->
        {:ok, :allowed}

      {:error, :rate_limited, retry_after} ->
        # Return the error directly since we want a specific format
        {:error, :rate_limited, retry_after}
    end
  end

  defp parse_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> {:ok, %{}}
      %{"_json" => _} -> {:error, :invalid_param, "request body must be a JSON object"}
      params when is_map(params) -> {:ok, params}
      _ -> {:error, :invalid_param, "request body must be a JSON object"}
    end
  end

  defp parse_game_type_param(nil), do: {:error, :missing_param, "game_type is required"}

  defp parse_game_type_param(game_type) when is_binary(game_type) do
    if String.trim(game_type) == "" do
      {:error, :invalid_param, "game_type must be a non-empty string"}
    else
      {:ok, game_type}
    end
  end

  defp parse_game_type_param(_),
    do: {:error, :invalid_param, "game_type must be a non-empty string"}

  defp viewer_from_conn(conn) do
    case authorization_header(conn) do
      :none ->
        {:ok, "spectator"}

      {:bearer, token} ->
        case LemonGames.Auth.validate_token(token) do
          {:ok, claims} -> {:ok, claims["agent_id"]}
          {:error, reason} -> error(conn, 401, "auth_failed", to_string(reason))
        end

      _ ->
        error(conn, 401, "auth_required", "Bearer token required")
    end
  end

  defp authorization_header(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        :none

      [header] ->
        case Regex.run(~r/^(?i:bearer) +([^\s,]+)$/u, header, capture: :all_but_first) do
          [token] -> {:bearer, token}
          _ -> :invalid
        end

      _multiple ->
        :invalid
    end
  end

  defp actor_slot(match, actor) do
    case Enum.find(match["players"] || %{}, fn {_, p} -> p["agent_id"] == actor["agent_id"] end) do
      {slot, _} -> slot
      nil -> "spectator"
    end
  end

  defp parse_non_neg_int_param(nil, default), do: {:ok, default}

  defp parse_non_neg_int_param(val, _default) when is_integer(val) and val >= 0,
    do: {:ok, val}

  defp parse_non_neg_int_param(val, _default) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_param, "after_seq must be a non-negative integer"}
    end
  end

  defp parse_non_neg_int_param(_val, _default),
    do: {:error, :invalid_param, "after_seq must be a non-negative integer"}

  defp parse_limit_param(nil, default), do: {:ok, default}

  defp parse_limit_param(val, _default) when is_integer(val) and val >= 1 and val <= 200,
    do: {:ok, val}

  defp parse_limit_param(val, _default) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} when n >= 1 and n <= 200 -> {:ok, n}
      _ -> {:error, :invalid_param, "limit must be an integer between 1 and 200"}
    end
  end

  defp parse_limit_param(_val, _default),
    do: {:error, :invalid_param, "limit must be an integer between 1 and 200"}

  defp parse_move_param(nil), do: {:error, :missing_param, "move is required"}
  defp parse_move_param(move) when is_map(move), do: {:ok, move}
  defp parse_move_param(_), do: {:error, :invalid_param, "move must be an object"}

  defp parse_idempotency_key_param(nil),
    do: {:error, :missing_param, "idempotency_key is required"}

  defp parse_idempotency_key_param(key) when is_binary(key) do
    if String.trim(key) == "" do
      {:error, :invalid_param, "idempotency_key must be a non-empty string"}
    else
      {:ok, key}
    end
  end

  defp parse_idempotency_key_param(_),
    do: {:error, :invalid_param, "idempotency_key must be a non-empty string"}

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
