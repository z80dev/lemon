defmodule LemonControlPlane.AgentIdentityStore do
  @moduledoc """
  Typed wrapper for persisted agent identity records.
  """

  alias LemonCore.Store

  @table :agents

  @spec get(binary()) :: map() | nil
  def get(agent_id) when is_binary(agent_id), do: Store.get(@table, agent_id)

  @spec put(binary(), map()) :: :ok | {:error, term()}
  def put(agent_id, agent) when is_binary(agent_id) and is_map(agent),
    do: Store.put(@table, agent_id, agent)

  @spec delete(binary()) :: :ok | {:error, term()}
  def delete(agent_id) when is_binary(agent_id), do: Store.delete(@table, agent_id)
end
