defmodule LemonGames.RateLimitStore do
  @moduledoc """
  Typed wrapper around LemonGames rate limit window storage.
  """

  alias LemonCore.Store

  @table :game_rate_limits

  @spec get(term()) :: [non_neg_integer()] | nil
  def get(key), do: Store.get(@table, wrap_key(key))

  @spec put(term(), [non_neg_integer()]) :: :ok | {:error, term()}
  def put(key, timestamps) when is_list(timestamps),
    do: Store.put(@table, wrap_key(key), timestamps)

  @spec delete(term()) :: :ok
  def delete(key), do: Store.delete(@table, wrap_key(key))

  @spec list() :: list()
  def list do
    @table
    |> Store.list()
    |> Enum.map(fn
      {{:rate, key}, value} -> {key, value}
      other -> other
    end)
  end

  defp wrap_key(key), do: {:rate, key}
end
