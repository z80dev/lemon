defmodule LemonGames.Games.Registry do
  @moduledoc """
  Maps game type strings to engine modules.
  """

  @engines %{
    "rock_paper_scissors" => LemonGames.Games.RockPaperScissors,
    "connect4" => LemonGames.Games.Connect4
  }

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(game_type) do
    case Map.fetch(@engines, game_type) do
      {:ok, mod} -> {:ok, mod}
      :error -> :error
    end
  end

  @spec fetch!(String.t()) :: module()
  def fetch!(game_type) do
    case fetch(game_type) do
      {:ok, mod} -> mod
      :error -> raise ArgumentError, "unknown game type: #{inspect(game_type)}"
    end
  end

  @spec supported_types() :: [String.t()]
  def supported_types, do: Map.keys(@engines)
end
