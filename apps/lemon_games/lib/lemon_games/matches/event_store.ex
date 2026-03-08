defmodule LemonGames.Matches.EventStore do
  @moduledoc """
  Typed wrapper around persistent match event storage.
  """

  alias LemonCore.Store

  @table :game_match_events

  @spec get(binary(), non_neg_integer()) :: map() | nil
  def get(match_id, seq) when is_binary(match_id) and is_integer(seq),
    do: Store.get(@table, {match_id, seq})

  @spec put(binary(), non_neg_integer(), map()) :: :ok | {:error, term()}
  def put(match_id, seq, event) when is_binary(match_id) and is_integer(seq) and is_map(event),
    do: Store.put(@table, {match_id, seq}, event)

  @spec delete(binary(), non_neg_integer()) :: :ok
  def delete(match_id, seq) when is_binary(match_id) and is_integer(seq),
    do: Store.delete(@table, {match_id, seq})

  @spec list() :: list()
  def list, do: Store.list(@table)
end
