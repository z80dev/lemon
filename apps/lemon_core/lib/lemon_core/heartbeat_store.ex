defmodule LemonCore.HeartbeatStore do
  @moduledoc """
  Typed wrapper for heartbeat configuration and last-result tables.
  """

  alias LemonCore.Store

  @config_table :heartbeat_config
  @last_table :heartbeat_last

  @spec get_config(binary()) :: map() | nil
  def get_config(agent_id) when is_binary(agent_id), do: Store.get(@config_table, agent_id)

  @spec put_config(binary(), map()) :: :ok
  def put_config(agent_id, config) when is_binary(agent_id) and is_map(config),
    do: Store.put(@config_table, agent_id, config)

  @spec delete_config(binary()) :: :ok
  def delete_config(agent_id) when is_binary(agent_id), do: Store.delete(@config_table, agent_id)

  @spec list_configs() :: list()
  def list_configs, do: Store.list(@config_table)

  @spec get_last(binary()) :: map() | nil
  def get_last(agent_id) when is_binary(agent_id), do: Store.get(@last_table, agent_id)

  @spec put_last(binary(), map()) :: :ok
  def put_last(agent_id, result) when is_binary(agent_id) and is_map(result),
    do: Store.put(@last_table, agent_id, result)

  @spec delete_last(binary()) :: :ok
  def delete_last(agent_id) when is_binary(agent_id), do: Store.delete(@last_table, agent_id)

  @spec list_last() :: list()
  def list_last, do: Store.list(@last_table)
end
