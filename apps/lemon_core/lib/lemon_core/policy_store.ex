defmodule LemonCore.PolicyStore do
  @moduledoc """
  Typed wrapper for policy domain storage.
  """

  alias LemonCore.Store

  @spec get_agent(binary()) :: map() | nil
  def get_agent(agent_id), do: Store.get_agent_policy(agent_id)

  @spec put_agent(binary(), map()) :: :ok | {:error, term()}
  def put_agent(agent_id, policy), do: Store.put_agent_policy(agent_id, policy)

  @spec get_channel(binary()) :: map() | nil
  def get_channel(channel_id), do: Store.get_channel_policy(channel_id)

  @spec put_channel(binary(), map()) :: :ok | {:error, term()}
  def put_channel(channel_id, policy), do: Store.put_channel_policy(channel_id, policy)

  @spec get_session(binary()) :: map() | nil
  def get_session(session_key), do: Store.get_session_policy(session_key)

  @spec put_session(binary(), map()) :: :ok | {:error, term()}
  def put_session(session_key, policy), do: Store.put_session_policy(session_key, policy)

  @spec delete_session(binary()) :: :ok
  def delete_session(session_key), do: Store.delete_session_policy(session_key)

  @spec get_runtime() :: map() | nil
  def get_runtime, do: Store.get_runtime_policy()

  @spec put_runtime(map()) :: :ok | {:error, term()}
  def put_runtime(policy), do: Store.put_runtime_policy(policy)

  @spec delete_runtime() :: :ok
  def delete_runtime, do: Store.delete_runtime_policy()
end
