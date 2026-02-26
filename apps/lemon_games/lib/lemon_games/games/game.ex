defmodule LemonGames.Games.Game do
  @moduledoc """
  Behaviour for game engines.

  Each game engine implements this behaviour to define game-specific rules,
  move validation, state transitions, and win detection.
  """

  @doc "Returns the game type string identifier."
  @callback game_type() :: String.t()

  @doc "Returns the initial game state for the given options."
  @callback init(opts :: map()) :: map()

  @doc "Returns legal moves for the given player slot."
  @callback legal_moves(state :: map(), slot :: String.t()) :: [map()]

  @doc "Applies a move and returns updated state or error."
  @callback apply_move(state :: map(), slot :: String.t(), move :: map()) ::
              {:ok, map()} | {:error, atom(), String.t()}

  @doc "Returns the winner slot (\"p1\"/\"p2\"), \"draw\", or nil if not terminal."
  @callback winner(state :: map()) :: String.t() | nil

  @doc "Returns the reason for game termination, or nil."
  @callback terminal_reason(state :: map()) :: String.t() | nil

  @doc "Returns the state visible to the given viewer, with redaction as needed."
  @callback public_state(state :: map(), viewer :: String.t()) :: map()
end
