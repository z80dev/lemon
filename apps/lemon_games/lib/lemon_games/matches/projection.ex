defmodule LemonGames.Matches.Projection do
  @moduledoc """
  Replays events to derive current game state and projects public views.
  """

  alias LemonGames.Games.Registry

  @spec replay(String.t(), [map()]) :: {map(), String.t() | nil}
  def replay(game_type, events) do
    engine = Registry.fetch!(game_type)
    init_state = engine.init(%{})

    Enum.reduce(events, {init_state, nil}, fn event, {state, _terminal} ->
      case event["event_type"] do
        "move_submitted" ->
          slot = get_in(event, ["actor", "slot"])
          move = event["payload"]["move"]

          case engine.apply_move(state, slot, move) do
            {:ok, new_state} ->
              {new_state, engine.terminal_reason(new_state)}

            {:error, _, _} ->
              # Skip rejected moves during replay
              {state, nil}
          end

        _ ->
          {state, nil}
      end
    end)
  end

  @spec project_public_view(map(), String.t()) :: map()
  def project_public_view(match, viewer) do
    engine = Registry.fetch!(match["game_type"])
    game_state = engine.public_state(match["snapshot_state"], viewer)

    %{
      "id" => match["id"],
      "game_type" => match["game_type"],
      "status" => match["status"],
      "visibility" => match["visibility"],
      "players" => redact_players(match["players"], viewer),
      "turn_number" => match["turn_number"],
      "next_player" => match["next_player"],
      "result" => match["result"],
      "game_state" => game_state,
      "deadline_at_ms" => match["deadline_at_ms"],
      "inserted_at_ms" => match["inserted_at_ms"],
      "updated_at_ms" => match["updated_at_ms"]
    }
  end

  @spec compute_next_player(map(), String.t()) :: String.t() | nil
  def compute_next_player(game_state, game_type) do
    engine = Registry.fetch!(game_type)

    cond do
      engine.terminal_reason(game_state) != nil ->
        nil

      game_type == "rock_paper_scissors" ->
        # Both players can move simultaneously in RPS
        cond do
          not Map.has_key?(game_state["throws"], "p1") -> "p1"
          not Map.has_key?(game_state["throws"], "p2") -> "p2"
          true -> nil
        end

      true ->
        # Alternating turns: default p1 first
        nil
    end
  end

  defp redact_players(players, _viewer) do
    # In MVP, no redaction needed for player info
    players
  end
end
