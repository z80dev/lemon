defmodule LemonCore.ExecApprovalStore do
  @moduledoc """
  Typed wrapper for execution approval policy and pending-request tables.
  """

  alias LemonCore.Store

  @global_policy_table :exec_approvals_policy
  @agent_policy_table :exec_approvals_policy_agent
  @session_policy_table :exec_approvals_policy_session
  @node_policy_table :exec_approvals_policy_node
  @global_policy_map_table :exec_approvals_policy_map
  @node_policy_map_table :exec_approvals_policy_node_map
  @pending_table :exec_approvals_pending

  @spec get_global_policy(term(), term()) :: map() | nil
  def get_global_policy(tool, action_hash),
    do: Store.get(@global_policy_table, {tool, action_hash})

  @spec put_global_policy(term(), term(), map()) :: :ok
  def put_global_policy(tool, action_hash, value),
    do: Store.put(@global_policy_table, {tool, action_hash}, value)

  @spec list_global_policies() :: list()
  def list_global_policies, do: Store.list(@global_policy_table)

  @spec get_agent_policy(binary(), term(), term()) :: map() | nil
  def get_agent_policy(agent_id, tool, action_hash),
    do: Store.get(@agent_policy_table, {agent_id, tool, action_hash})

  @spec put_agent_policy(binary(), term(), term(), map()) :: :ok
  def put_agent_policy(agent_id, tool, action_hash, value),
    do: Store.put(@agent_policy_table, {agent_id, tool, action_hash}, value)

  @spec list_agent_policies() :: list()
  def list_agent_policies, do: Store.list(@agent_policy_table)

  @spec get_session_policy(binary(), term(), term()) :: map() | nil
  def get_session_policy(session_key, tool, action_hash),
    do: Store.get(@session_policy_table, {session_key, tool, action_hash})

  @spec put_session_policy(binary(), term(), term(), map()) :: :ok
  def put_session_policy(session_key, tool, action_hash, value),
    do: Store.put(@session_policy_table, {session_key, tool, action_hash}, value)

  @spec list_session_policies() :: list()
  def list_session_policies, do: Store.list(@session_policy_table)

  @spec get_node_policy(binary(), term(), term()) :: map() | nil
  def get_node_policy(node_id, tool, action_hash),
    do: Store.get(@node_policy_table, {node_id, tool, action_hash})

  @spec put_node_policy(binary(), term(), term(), map()) :: :ok
  def put_node_policy(node_id, tool, action_hash, value),
    do: Store.put(@node_policy_table, {node_id, tool, action_hash}, value)

  @spec list_node_policies() :: list()
  def list_node_policies, do: Store.list(@node_policy_table)

  @spec get_global_policy_map() :: map() | nil
  def get_global_policy_map, do: Store.get(@global_policy_map_table, :global)

  @spec put_global_policy_map(map()) :: :ok
  def put_global_policy_map(value) when is_map(value),
    do: Store.put(@global_policy_map_table, :global, value)

  @spec get_node_policy_map(binary()) :: map() | nil
  def get_node_policy_map(node_id) when is_binary(node_id),
    do: Store.get(@node_policy_map_table, node_id)

  @spec put_node_policy_map(binary(), map()) :: :ok
  def put_node_policy_map(node_id, value) when is_binary(node_id) and is_map(value),
    do: Store.put(@node_policy_map_table, node_id, value)

  @spec put_pending(binary(), map()) :: :ok
  def put_pending(approval_id, value) when is_binary(approval_id) and is_map(value),
    do: Store.put(@pending_table, approval_id, value)

  @spec get_pending(binary()) :: map() | nil
  def get_pending(approval_id) when is_binary(approval_id),
    do: Store.get(@pending_table, approval_id)

  @spec delete_pending(binary()) :: :ok
  def delete_pending(approval_id) when is_binary(approval_id),
    do: Store.delete(@pending_table, approval_id)

  @spec list_pending() :: list()
  def list_pending, do: Store.list(@pending_table)
end
