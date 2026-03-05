defmodule LemonSim.Examples.TicTacToe.Outcome do
  @moduledoc false

  defstruct [:status, :winner, :next_player, events: []]

  @type t :: %__MODULE__{
          status: String.t(),
          winner: String.t() | nil,
          next_player: String.t() | nil,
          events: [LemonSim.Event.t()]
        }
end
