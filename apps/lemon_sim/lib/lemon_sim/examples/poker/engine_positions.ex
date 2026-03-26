defmodule LemonSim.Examples.Poker.Engine.Positions do
  @moduledoc """
  Position label helpers for no-limit hold'em tables.
  """

  alias LemonSim.Examples.Poker.Engine.Table

  @spec label(
          pos_integer(),
          pos_integer() | nil,
          pos_integer() | nil,
          pos_integer() | nil,
          [pos_integer()]
        ) :: String.t()
  def label(seat, button_seat, sb_seat, bb_seat, active_seats) do
    Table.position_label(seat, button_seat, sb_seat, bb_seat, active_seats) || "??"
  end
end
