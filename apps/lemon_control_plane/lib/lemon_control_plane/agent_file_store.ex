defmodule LemonControlPlane.AgentFileStore do
  @moduledoc """
  Typed wrapper for persisted agent files.
  """

  alias LemonCore.Store

  @table :agent_files

  @spec get(binary(), binary()) :: map() | nil
  def get(agent_id, file_name) when is_binary(agent_id) and is_binary(file_name),
    do: Store.get(@table, {agent_id, file_name})

  @spec get_legacy(binary()) :: term()
  def get_legacy(agent_id) when is_binary(agent_id), do: Store.get(@table, agent_id)

  @spec put(binary(), binary(), map()) :: :ok
  def put(agent_id, file_name, value)
      when is_binary(agent_id) and is_binary(file_name) and is_map(value),
      do: Store.put(@table, {agent_id, file_name}, value)

  @spec list() :: list()
  def list, do: Store.list(@table)
end
