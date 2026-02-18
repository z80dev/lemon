defmodule LemonPoker do
  @moduledoc """
  No-limit hold'em engine entrypoints.

  The full game logic lives in `LemonPoker.Table`.
  """

  alias LemonPoker.Table

  @type action ::
          :fold
          | :check
          | :call
          | {:bet, non_neg_integer()}
          | {:raise, non_neg_integer()}

  @doc """
  Creates a new table state.

  See `LemonPoker.Table.new/2` for options.
  """
  @spec new_table(String.t(), keyword()) :: Table.t()
  defdelegate new_table(id, opts \\ []), to: Table, as: :new

  @doc """
  Seats a player.
  """
  @spec seat_player(Table.t(), pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, Table.t()} | {:error, atom()}
  defdelegate seat_player(table, seat, player_id, stack), to: Table

  @doc """
  Starts a new hand when at least two players are active.
  """
  @spec start_hand(Table.t(), keyword()) :: {:ok, Table.t()} | {:error, atom()}
  defdelegate start_hand(table, opts \\ []), to: Table

  @doc """
  Returns legal options for the current actor.
  """
  @spec legal_actions(Table.t()) :: {:ok, map()} | {:error, atom()}
  defdelegate legal_actions(table), to: Table

  @doc """
  Applies an action for the acting player.
  """
  @spec act(Table.t(), pos_integer(), action()) :: {:ok, Table.t()} | {:error, atom()}
  defdelegate act(table, seat, action), to: Table
end
