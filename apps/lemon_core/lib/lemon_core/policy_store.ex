defmodule LemonCore.PolicyStore do
  @moduledoc """
  Typed wrapper for policy domain storage.

  Provides scoped access to agent, channel, session, and runtime policies
  stored in `LemonCore.Store`.
  """

  alias LemonCore.Store

  @doc "Fetches the policy for the given agent, or `nil` if not set."
  @spec get_agent(binary()) :: map() | nil
  def get_agent(agent_id), do: Store.get_agent_policy(agent_id)

  @doc "Stores a policy for the given agent."
  @spec put_agent(binary(), map()) :: :ok | {:error, term()}
  def put_agent(agent_id, policy), do: Store.put_agent_policy(agent_id, policy)

  @doc "Fetches the policy for the given channel, or `nil` if not set."
  @spec get_channel(binary()) :: map() | nil
  def get_channel(channel_id), do: Store.get_channel_policy(channel_id)

  @doc "Stores a policy for the given channel."
  @spec put_channel(binary(), map()) :: :ok | {:error, term()}
  def put_channel(channel_id, policy), do: Store.put_channel_policy(channel_id, policy)

  @doc "Fetches the policy for the given session, or `nil` if not set."
  @spec get_session(binary()) :: map() | nil
  def get_session(session_key), do: Store.get_session_policy(session_key)

  @doc "Stores a policy for the given session."
  @spec put_session(binary(), map()) :: :ok | {:error, term()}
  def put_session(session_key, policy), do: Store.put_session_policy(session_key, policy)

  @doc "Deletes the policy for the given session."
  @spec delete_session(binary()) :: :ok
  def delete_session(session_key), do: Store.delete_session_policy(session_key)

  @doc "Fetches the runtime policy, or `nil` if not set."
  @spec get_runtime() :: map() | nil
  def get_runtime, do: Store.get_runtime_policy()

  @doc "Stores the runtime policy."
  @spec put_runtime(map()) :: :ok | {:error, term()}
  def put_runtime(policy), do: Store.put_runtime_policy(policy)

  @doc "Deletes the runtime policy."
  @spec delete_runtime() :: :ok
  def delete_runtime, do: Store.delete_runtime_policy()
end
