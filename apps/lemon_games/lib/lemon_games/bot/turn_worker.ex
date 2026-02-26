defmodule LemonGames.Bot.TurnWorker do
  @moduledoc "Processes bot turns asynchronously."

  require Logger

  alias LemonGames.Matches.Service

  @spec maybe_play_bot_turn(map()) :: :ok | :skip
  def maybe_play_bot_turn(match) do
    next = match["next_player"]

    if next && is_bot?(match, next) do
      play_turn(match, next)
    else
      :skip
    end
  end

  defp play_turn(match, slot) do
    bot_info = get_in(match, ["players", slot])
    actor = %{"agent_id" => bot_info["agent_id"]}
    game_type = match["game_type"]
    state = match["snapshot_state"]

    move = choose_move(game_type, state, slot)
    idem_key = "bot_#{match["id"]}_#{match["turn_number"]}_#{slot}"

    case Service.submit_move(match["id"], actor, move, idem_key) do
      {:ok, updated, _seq} ->
        Logger.debug("[BotTurnWorker] Bot #{slot} played in match #{match["id"]}")
        # Recursively check if it's still a bot's turn (e.g., after RPS p1, check p2)
        maybe_play_bot_turn(updated)

      {:error, :invalid_state, msg} ->
        # Benign race: another async turn worker may have already advanced/finished this match.
        Logger.debug("[BotTurnWorker] Skipping bot move due to state transition: #{msg}")
        :ok

      {:error, code, msg} ->
        Logger.warning("[BotTurnWorker] Bot move failed: #{code} - #{msg}")
        :ok
    end
  end

  defp choose_move("rock_paper_scissors", state, slot) do
    LemonGames.Bot.RockPaperScissorsBot.choose_move(state, slot)
  end

  defp choose_move("connect4", state, slot) do
    LemonGames.Bot.Connect4Bot.choose_move(state, slot)
  end

  defp choose_move(_game_type, _state, _slot) do
    raise "No bot strategy for game type"
  end

  defp is_bot?(match, slot) do
    case get_in(match, ["players", slot]) do
      %{"agent_type" => "lemon_bot"} -> true
      _ -> false
    end
  end
end
