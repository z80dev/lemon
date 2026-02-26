defmodule LemonGames.Matches.Service do
  @moduledoc """
  Match lifecycle service.

  Handles creation, acceptance, move submission, forfeits, and expiry.
  All mutating operations use per-match global locks for consistency.
  """

  alias LemonGames.Games.Registry
  alias LemonGames.Matches.{EventLog, Match, Projection}
  alias LemonGames.Bus

  @match_table :game_matches

  # --- Public API ---

  @spec create_match(map(), map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def create_match(params, actor) do
    with {:ok, _engine} <- Registry.fetch(params["game_type"]) |> wrap_registry_error() do
      match =
        params
        |> Map.put("created_by", actor["agent_id"])
        |> Match.new()
        |> Match.add_player("p1", %{
          "agent_id" => actor["agent_id"],
          "agent_type" => "external_agent",
          "display_name" => actor["display_name"] || actor["agent_id"]
        })

      # Add bot opponent if requested
      match =
        case params["opponent"] do
          %{"type" => "lemon_bot"} ->
            bot_id = params["opponent"]["bot_id"] || "default"

            Match.add_player(match, "p2", %{
              "agent_id" => "lemon_bot_" <> bot_id,
              "agent_type" => "lemon_bot",
              "display_name" => "Lemon Bot"
            })

          _ ->
            match
        end

      # Auto-accept if bot opponent (both players present)
      match =
        if map_size(match["players"]) == 2 do
          activate_match(match)
        else
          match
        end

      :ok = LemonCore.Store.put(@match_table, match["id"], match)

      EventLog.append(match["id"], "match_created", %{"agent_id" => actor["agent_id"]}, %{
        "game_type" => match["game_type"],
        "players" => match["players"]
      })

      Bus.broadcast_lobby_changed(match["id"], match["status"], "match_created")

      # Trigger bot turn if next player is a bot
      Task.start(fn -> LemonGames.Bot.TurnWorker.maybe_play_bot_turn(match) end)

      {:ok, match}
    end
  end

  @spec accept_match(String.t(), map()) :: {:ok, map()} | {:error, atom(), String.t()}
  def accept_match(match_id, actor) do
    with_lock(match_id, fn ->
      with {:ok, match} <- fetch_match(match_id),
           :ok <- assert_status(match, "pending_accept"),
           :ok <- assert_not_player(match, actor["agent_id"]) do
        match =
          match
          |> Match.add_player("p2", %{
            "agent_id" => actor["agent_id"],
            "agent_type" => "external_agent",
            "display_name" => actor["display_name"] || actor["agent_id"]
          })
          |> activate_match()

        :ok = LemonCore.Store.put(@match_table, match_id, match)

        EventLog.append(match_id, "accepted", %{"agent_id" => actor["agent_id"]}, %{})

        Bus.broadcast_lobby_changed(match_id, "active", "accepted")
        {:ok, match}
      end
    end)
  end

  @spec submit_move(String.t(), map(), map(), String.t()) ::
          {:ok, map(), non_neg_integer()} | {:error, atom(), String.t()}
  def submit_move(match_id, actor, move, idempotency_key) do
    scope = "game_move:" <> match_id <> ":" <> (actor["agent_id"] || "anonymous")

    case LemonCore.Idempotency.get(scope, idempotency_key) do
      {:ok, cached} ->
        {:ok, cached["match"], cached["seq"]}

      :miss ->
        result = do_submit_move(match_id, actor, move)

        case result do
          {:ok, match, seq} ->
            LemonCore.Idempotency.put(scope, idempotency_key, %{
              "match" => match,
              "seq" => seq
            })

            result

          error ->
            error
        end
    end
  end

  @spec get_match(String.t(), String.t()) :: {:ok, map()} | {:error, atom(), String.t()}
  def get_match(match_id, viewer) do
    with {:ok, match} <- fetch_match(match_id),
         :ok <- assert_view_allowed(match, viewer) do
      public = Projection.project_public_view(match, viewer)
      {:ok, public}
    end
  end

  @spec list_lobby(map()) :: [map()]
  def list_lobby(_opts \\ %{}) do
    @match_table
    |> LemonCore.Store.list()
    |> Enum.map(fn {_key, match} -> match end)
    |> Enum.filter(fn m -> m["visibility"] == "public" end)
    |> Enum.sort_by(fn m -> -m["updated_at_ms"] end)
    |> Enum.map(fn m -> Projection.project_public_view(m, "spectator") end)
  end

  @spec list_events(String.t(), non_neg_integer(), non_neg_integer(), String.t()) ::
          {:ok, [map()], non_neg_integer(), boolean()}
  def list_events(match_id, after_seq, limit, viewer) do
    with {:ok, match} <- fetch_match(match_id),
         :ok <- assert_view_allowed(match, viewer) do
      events = EventLog.list(match_id, after_seq, limit + 1)
      has_more = length(events) > limit
      events = Enum.take(events, limit)
      events = redact_events(match, viewer, events)

      next_after_seq =
        case List.last(events) do
          nil -> after_seq
          e -> e["seq"]
        end

      {:ok, events, next_after_seq, has_more}
    end
  end

  @spec forfeit_match(String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, atom(), String.t()}
  def forfeit_match(match_id, actor, reason) do
    with_lock(match_id, fn ->
      with {:ok, match} <- fetch_match(match_id),
           :ok <- assert_status(match, "active"),
           {:ok, slot} <- find_player_slot(match, actor["agent_id"]) do
        winner = if slot == "p1", do: "p2", else: "p1"
        match = finish_match(match, winner, "forfeit: " <> reason)

        :ok = LemonCore.Store.put(@match_table, match_id, match)

        EventLog.append(
          match_id,
          "finished",
          %{"agent_id" => actor["agent_id"], "slot" => slot},
          %{
            "result" => match["result"],
            "reason" => reason
          }
        )

        Bus.broadcast_lobby_changed(match_id, "finished", "forfeit")

        Bus.broadcast_match_event(match_id, %{
          "match_id" => match_id,
          "seq" => EventLog.latest_seq(match_id),
          "event_type" => "finished",
          "status" => "finished",
          "next_player" => nil,
          "turn_number" => match["turn_number"]
        })

        {:ok, match}
      end
    end)
  end

  @spec expire_match(String.t(), String.t()) :: {:ok, map()} | {:error, atom(), String.t()}
  def expire_match(match_id, reason) do
    with_lock(match_id, fn ->
      with {:ok, match} <- fetch_match(match_id),
           :ok <- assert_not_terminal(match) do
        match =
          match
          |> Map.put("status", "expired")
          |> Map.put("result", %{"reason" => reason})
          |> Map.put("updated_at_ms", System.system_time(:millisecond))

        :ok = LemonCore.Store.put(@match_table, match_id, match)

        EventLog.append(match_id, "expired", %{"system" => true}, %{"reason" => reason})

        Bus.broadcast_lobby_changed(match_id, "expired", "expired")
        {:ok, match}
      end
    end)
  end

  # --- Private Helpers ---

  defp do_submit_move(match_id, actor, move) do
    with_lock(match_id, fn ->
      with {:ok, match} <- fetch_match(match_id),
           :ok <- assert_status(match, "active"),
           {:ok, slot} <- find_player_slot(match, actor["agent_id"]),
           :ok <- assert_turn(match, slot) do
        engine = Registry.fetch!(match["game_type"])

        case engine.apply_move(match["snapshot_state"], slot, move) do
          {:ok, new_state} ->
            {:ok, seq} =
              EventLog.append(
                match_id,
                "move_submitted",
                %{"agent_id" => actor["agent_id"], "slot" => slot},
                %{"move" => move}
              )

            terminal = engine.terminal_reason(new_state)
            winner = engine.winner(new_state)

            match =
              match
              |> Map.put("snapshot_state", new_state)
              |> Map.put("snapshot_seq", seq)
              |> Map.put("updated_at_ms", System.system_time(:millisecond))
              |> advance_turn(terminal, winner)

            :ok = LemonCore.Store.put(@match_table, match_id, match)

            Bus.broadcast_match_event(match_id, %{
              "match_id" => match_id,
              "seq" => seq,
              "event_type" => "move_submitted",
              "status" => match["status"],
              "next_player" => match["next_player"],
              "turn_number" => match["turn_number"]
            })

            if terminal do
              Bus.broadcast_lobby_changed(match_id, "finished", "game_over")
            end

            # Trigger bot turn if next player is a bot
            Task.start(fn -> LemonGames.Bot.TurnWorker.maybe_play_bot_turn(match) end)

            {:ok, match, seq}

          {:error, code, message} ->
            EventLog.append(
              match_id,
              "move_rejected",
              %{"agent_id" => actor["agent_id"], "slot" => slot},
              %{"move" => move, "reason" => message}
            )

            {:error, code, message}
        end
      end
    end)
  end

  defp activate_match(match) do
    engine = Registry.fetch!(match["game_type"])
    init_state = engine.init(%{})

    match
    |> Map.put("status", "active")
    |> Map.put("snapshot_state", init_state)
    |> Map.put("turn_number", 1)
    |> Map.put("next_player", initial_next_player(match["game_type"]))
    |> Map.put(
      "deadline_at_ms",
      System.system_time(:millisecond) + Match.turn_timeout_ms(match["game_type"])
    )
    |> Map.put("updated_at_ms", System.system_time(:millisecond))
  end

  defp advance_turn(match, terminal, winner) when terminal != nil do
    finish_match(match, winner, terminal)
  end

  defp advance_turn(match, _terminal, _winner) do
    next = compute_alternating_next(match)

    match
    |> Map.put("turn_number", match["turn_number"] + 1)
    |> Map.put("next_player", next)
    |> Map.put(
      "deadline_at_ms",
      System.system_time(:millisecond) + Match.turn_timeout_ms(match["game_type"])
    )
  end

  defp finish_match(match, winner, reason) do
    match
    |> Map.put("status", "finished")
    |> Map.put("next_player", nil)
    |> Map.put("result", %{"winner" => winner, "reason" => reason})
    |> Map.put("updated_at_ms", System.system_time(:millisecond))
  end

  defp initial_next_player("rock_paper_scissors"), do: "p1"
  defp initial_next_player(_), do: "p1"

  defp compute_alternating_next(match) do
    game_type = match["game_type"]

    case game_type do
      "rock_paper_scissors" ->
        # RPS: both can move; after p1 moves, p2 goes
        throws = match["snapshot_state"]["throws"] || %{}

        cond do
          not Map.has_key?(throws, "p1") -> "p1"
          not Map.has_key?(throws, "p2") -> "p2"
          true -> nil
        end

      _ ->
        # Alternating: flip between p1 and p2
        if match["next_player"] == "p1", do: "p2", else: "p1"
    end
  end

  defp fetch_match(match_id) do
    case LemonCore.Store.get(@match_table, match_id) do
      nil -> {:error, :not_found, "match not found"}
      match -> {:ok, match}
    end
  end

  defp assert_status(match, expected) do
    if match["status"] == expected do
      :ok
    else
      {:error, :invalid_state, "expected status #{expected}, got #{match["status"]}"}
    end
  end

  defp assert_not_terminal(match) do
    if Match.terminal?(match) do
      {:error, :invalid_state, "match is already terminal"}
    else
      :ok
    end
  end

  defp assert_not_player(match, agent_id) do
    players = match["players"] || %{}

    if Enum.any?(players, fn {_slot, p} -> p["agent_id"] == agent_id end) do
      {:error, :already_joined, "already a player in this match"}
    else
      :ok
    end
  end

  defp find_player_slot(match, agent_id) do
    case Enum.find(match["players"] || %{}, fn {_slot, p} -> p["agent_id"] == agent_id end) do
      {slot, _} -> {:ok, slot}
      nil -> {:error, :not_player, "not a player in this match"}
    end
  end

  defp assert_turn(match, slot) do
    game_type = match["game_type"]

    case game_type do
      "rock_paper_scissors" ->
        # RPS allows both players to move independently
        :ok

      _ ->
        if match["next_player"] == slot do
          :ok
        else
          {:error, :wrong_turn, "not your turn"}
        end
    end
  end

  defp assert_view_allowed(match, viewer) do
    if match["visibility"] == "private" and not private_viewer?(match, viewer) do
      {:error, :forbidden, "match is private"}
    else
      :ok
    end
  end

  defp private_viewer?(match, viewer) when is_binary(viewer) do
    viewer == match["created_by"] or
      Enum.any?(match["players"] || %{}, fn {_slot, player} -> player["agent_id"] == viewer end)
  end

  defp private_viewer?(_match, _viewer), do: false

  defp redact_events(match, viewer, events) do
    case match["game_type"] do
      "rock_paper_scissors" ->
        redact_rps_events(match, viewer, events)

      _ ->
        events
    end
  end

  defp redact_rps_events(match, viewer, events) do
    resolved? = get_in(match, ["snapshot_state", "resolved"]) == true

    if resolved? do
      events
    else
      viewer_slot =
        case Enum.find(match["players"] || %{}, fn {_slot, p} -> p["agent_id"] == viewer end) do
          {slot, _} -> slot
          nil -> nil
        end

      Enum.map(events, fn event ->
        case event do
          %{"event_type" => "move_submitted", "payload" => %{"move" => %{"kind" => "throw"}}} = e ->
            actor_slot = get_in(e, ["actor", "slot"])

            if viewer_slot != nil and actor_slot == viewer_slot do
              e
            else
              put_in(e, ["payload", "move", "value"], "hidden")
            end

          other ->
            other
        end
      end)
    end
  end

  defp with_lock(match_id, fun) do
    :global.trans({:lemon_games_match_lock, match_id}, fun)
  end

  defp wrap_registry_error({:ok, mod}), do: {:ok, mod}
  defp wrap_registry_error(:error), do: {:error, :unknown_game_type, "unsupported game type"}
end
