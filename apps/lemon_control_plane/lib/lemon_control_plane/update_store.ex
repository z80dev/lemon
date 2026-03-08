defmodule LemonControlPlane.UpdateStore do
  @moduledoc """
  Typed wrapper for control-plane update configuration and pending-update state.
  """

  alias LemonCore.Store

  @config_table :update_config
  @pending_table :pending_update
  @global_key :global
  @current_key :current

  @spec get_config() :: map() | nil
  def get_config, do: Store.get(@config_table, @global_key)

  @spec put_config(map()) :: :ok | {:error, term()}
  def put_config(config) when is_map(config), do: Store.put(@config_table, @global_key, config)

  @spec delete_config() :: :ok | {:error, term()}
  def delete_config, do: Store.delete(@config_table, @global_key)

  @spec get_pending() :: map() | nil
  def get_pending, do: Store.get(@pending_table, @current_key)

  @spec put_pending(map()) :: :ok | {:error, term()}
  def put_pending(update_info) when is_map(update_info),
    do: Store.put(@pending_table, @current_key, update_info)

  @spec delete_pending() :: :ok | {:error, term()}
  def delete_pending, do: Store.delete(@pending_table, @current_key)
end
