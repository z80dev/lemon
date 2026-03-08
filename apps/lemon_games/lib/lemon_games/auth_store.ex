defmodule LemonGames.AuthStore do
  @moduledoc """
  Typed wrapper around token claims storage for LemonGames auth.
  """

  alias LemonCore.Store

  @table :game_agent_tokens

  @spec get(binary()) :: map() | nil
  def get(token_hash) when is_binary(token_hash), do: Store.get(@table, token_hash)

  @spec put(binary(), map()) :: :ok | {:error, term()}
  def put(token_hash, claims) when is_binary(token_hash) and is_map(claims),
    do: Store.put(@table, token_hash, claims)

  @spec delete(binary()) :: :ok
  def delete(token_hash) when is_binary(token_hash), do: Store.delete(@table, token_hash)

  @spec list() :: list()
  def list, do: Store.list(@table)
end
