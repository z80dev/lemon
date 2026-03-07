defmodule LemonRouter.AgentEndpointStore do
  @moduledoc """
  Router-owned typed wrapper for persistent agent endpoint aliases.
  """

  alias LemonCore.Store

  @table :agent_endpoints

  @spec get(binary(), binary()) :: map() | nil
  def get(agent_id, name) when is_binary(agent_id) and is_binary(name),
    do: Store.get(@table, {agent_id, name})

  @spec put(binary(), binary(), map()) :: :ok
  def put(agent_id, name, value)
      when is_binary(agent_id) and is_binary(name) and is_map(value),
      do: Store.put(@table, {agent_id, name}, value)

  @spec delete(binary(), binary()) :: :ok
  def delete(agent_id, name) when is_binary(agent_id) and is_binary(name),
    do: Store.delete(@table, {agent_id, name})

  @spec list() :: list()
  def list, do: Store.list(@table)
end
