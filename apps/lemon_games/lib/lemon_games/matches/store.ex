defmodule LemonGames.Matches.Store do
  @moduledoc """
  Typed wrapper around persistent match storage.
  """

  alias LemonCore.Store

  @table :game_matches

  @spec get(binary()) :: map() | nil
  def get(match_id) when is_binary(match_id), do: Store.get(@table, match_id)

  @spec put(binary(), map()) :: :ok | {:error, term()}
  def put(match_id, match) when is_binary(match_id) and is_map(match),
    do: Store.put(@table, match_id, match)

  @spec delete(binary()) :: :ok
  def delete(match_id) when is_binary(match_id), do: Store.delete(@table, match_id)

  @spec list() :: list()
  def list, do: Store.list(@table)
end
