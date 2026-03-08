defmodule LemonCore.ModelPolicyStore do
  @moduledoc """
  Typed wrapper for persisted model-policy records.
  """

  alias LemonCore.Store

  @table :model_policies

  @spec get(term()) :: map() | nil
  def get(key), do: Store.get(@table, key)

  @spec put(term(), map()) :: :ok | {:error, term()}
  def put(key, policy) when is_map(policy), do: Store.put(@table, key, policy)

  @spec delete(term()) :: :ok | {:error, term()}
  def delete(key), do: Store.delete(@table, key)

  @spec list() :: [{term(), map()}]
  def list, do: Store.list(@table)
end
