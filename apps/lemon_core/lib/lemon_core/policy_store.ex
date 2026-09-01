defmodule LemonCore.PolicyStore do
  @moduledoc """
  Policy overrides by agent, channel and session, and the global runtime
  policy.

  Owns four tables, one per scope. Values are the plain maps the policy
  readers interpret; this module only keys them:

    * `:agent_policies` by agent id
    * `:channel_policies` by channel id
    * `:session_policies` by session key
    * `:runtime_policy`, a single entry under `:global`
  """

  use LemonCore.Store.Table,
    tables: [
      agent_policies: [],
      channel_policies: [],
      session_policies: [],
      runtime_policy: []
    ]

  alias LemonCore.Store

  @agent :agent_policies
  @channel :channel_policies
  @session :session_policies
  @runtime :runtime_policy
  @runtime_key :global

  @type policy :: map()

  ## Agents

  @doc "The policy for `agent_id`, or `nil`."
  @spec get_agent(Store.server(), term()) :: policy() | nil
  def get_agent(server \\ Store, agent_id), do: Store.get(server, @agent, agent_id)

  @spec put_agent(Store.server(), term(), policy()) :: :ok | {:error, term()}
  def put_agent(server \\ Store, agent_id, policy),
    do: Store.put(server, @agent, agent_id, policy)

  @spec delete_agent(Store.server(), term()) :: :ok | {:error, term()}
  def delete_agent(server \\ Store, agent_id), do: Store.delete(server, @agent, agent_id)

  @spec list_agents(Store.server()) :: [{term(), policy()}]
  def list_agents(server \\ Store), do: Store.list(server, @agent)

  ## Channels

  @doc "The policy for `channel_id`, or `nil`."
  @spec get_channel(Store.server(), term()) :: policy() | nil
  def get_channel(server \\ Store, channel_id), do: Store.get(server, @channel, channel_id)

  @spec put_channel(Store.server(), term(), policy()) :: :ok | {:error, term()}
  def put_channel(server \\ Store, channel_id, policy) do
    Store.put(server, @channel, channel_id, policy)
  end

  @spec delete_channel(Store.server(), term()) :: :ok | {:error, term()}
  def delete_channel(server \\ Store, channel_id), do: Store.delete(server, @channel, channel_id)

  @spec list_channels(Store.server()) :: [{term(), policy()}]
  def list_channels(server \\ Store), do: Store.list(server, @channel)

  ## Sessions

  @doc "The policy for `session_key`, or `nil`."
  @spec get_session(Store.server(), term()) :: policy() | nil
  def get_session(server \\ Store, session_key), do: Store.get(server, @session, session_key)

  @spec put_session(Store.server(), term(), policy()) :: :ok | {:error, term()}
  def put_session(server \\ Store, session_key, policy) do
    Store.put(server, @session, session_key, policy)
  end

  @spec delete_session(Store.server(), term()) :: :ok | {:error, term()}
  def delete_session(server \\ Store, session_key),
    do: Store.delete(server, @session, session_key)

  @spec list_sessions(Store.server()) :: [{term(), policy()}]
  def list_sessions(server \\ Store), do: Store.list(server, @session)

  ## Runtime

  @doc "The global runtime policy overrides, or `nil`."
  @spec get_runtime(Store.server()) :: policy() | nil
  def get_runtime(server \\ Store), do: Store.get(server, @runtime, @runtime_key)

  @spec put_runtime(Store.server(), policy()) :: :ok | {:error, term()}
  def put_runtime(server \\ Store, policy), do: Store.put(server, @runtime, @runtime_key, policy)

  @spec delete_runtime(Store.server()) :: :ok | {:error, term()}
  def delete_runtime(server \\ Store), do: Store.delete(server, @runtime, @runtime_key)

  @spec list_runtime(Store.server()) :: [{term(), policy()}]
  def list_runtime(server \\ Store), do: Store.list(server, @runtime)
end
