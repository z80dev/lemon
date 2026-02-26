defmodule LemonGames.Games.RockPaperScissors do
  @moduledoc "Rock Paper Scissors game engine."
  @behaviour LemonGames.Games.Game

  @valid_throws ["rock", "paper", "scissors"]

  @impl true
  def game_type, do: "rock_paper_scissors"

  @impl true
  def init(_opts) do
    %{"throws" => %{}, "resolved" => false, "winner" => nil}
  end

  @impl true
  def legal_moves(state, slot) do
    if Map.has_key?(state["throws"], slot) do
      []
    else
      Enum.map(@valid_throws, fn v -> %{"kind" => "throw", "value" => v} end)
    end
  end

  @impl true
  def apply_move(state, slot, %{"kind" => "throw", "value" => value}) do
    cond do
      value not in @valid_throws ->
        {:error, :illegal_move, "invalid throw value: #{value}"}

      Map.has_key?(state["throws"], slot) ->
        {:error, :illegal_move, "already thrown"}

      true ->
        throws = Map.put(state["throws"], slot, value)
        state = Map.put(state, "throws", throws)

        if map_size(throws) == 2 do
          {:ok, resolve(state)}
        else
          {:ok, state}
        end
    end
  end

  def apply_move(_state, _slot, _move) do
    {:error, :illegal_move, "invalid move format"}
  end

  @impl true
  def winner(state), do: state["winner"]

  @impl true
  def terminal_reason(state) do
    case state["winner"] do
      nil -> nil
      "draw" -> "draw"
      _ -> "winner"
    end
  end

  @impl true
  def public_state(state, _viewer) do
    if state["resolved"] do
      state
    else
      # Hide opponent throws until resolved
      %{"throws" => %{}, "resolved" => false, "winner" => nil}
    end
  end

  defp resolve(state) do
    p1 = state["throws"]["p1"]
    p2 = state["throws"]["p2"]
    winner = determine_winner(p1, p2)
    %{state | "resolved" => true, "winner" => winner}
  end

  defp determine_winner(same, same), do: "draw"
  defp determine_winner("rock", "scissors"), do: "p1"
  defp determine_winner("paper", "rock"), do: "p1"
  defp determine_winner("scissors", "paper"), do: "p1"
  defp determine_winner(_, _), do: "p2"
end
