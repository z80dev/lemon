defmodule LemonControlPlane.NodeStore do
  @moduledoc """
  Typed wrapper for node pairing, registry, challenges, and invocations.
  """

  alias LemonCore.Store

  @pairing_table :nodes_pairing
  @pairing_code_table :nodes_pairing_by_code
  @registry_table :nodes_registry
  @challenge_table :node_challenges
  @invocation_table :node_invocations

  @spec put_pairing(binary(), map()) :: :ok
  def put_pairing(pairing_id, value) when is_binary(pairing_id) and is_map(value),
    do: Store.put(@pairing_table, pairing_id, value)

  @spec get_pairing(binary()) :: map() | nil
  def get_pairing(pairing_id) when is_binary(pairing_id),
    do: Store.get(@pairing_table, pairing_id)

  @spec list_pairings() :: list()
  def list_pairings, do: Store.list(@pairing_table)

  @spec put_pairing_code(binary(), binary()) :: :ok
  def put_pairing_code(code, pairing_id) when is_binary(code) and is_binary(pairing_id),
    do: Store.put(@pairing_code_table, code, pairing_id)

  @spec get_pairing_id_by_code(binary()) :: binary() | nil
  def get_pairing_id_by_code(code) when is_binary(code), do: Store.get(@pairing_code_table, code)

  @spec put_node(binary(), map()) :: :ok
  def put_node(node_id, node) when is_binary(node_id) and is_map(node),
    do: Store.put(@registry_table, node_id, node)

  @spec get_node(binary()) :: map() | nil
  def get_node(node_id) when is_binary(node_id), do: Store.get(@registry_table, node_id)

  @spec list_nodes() :: list()
  def list_nodes, do: Store.list(@registry_table)

  @spec put_challenge(binary(), map()) :: :ok
  def put_challenge(token, value) when is_binary(token) and is_map(value),
    do: Store.put(@challenge_table, token, value)

  @spec get_challenge(binary()) :: map() | nil
  def get_challenge(token) when is_binary(token), do: Store.get(@challenge_table, token)

  @spec delete_challenge(binary()) :: :ok
  def delete_challenge(token) when is_binary(token), do: Store.delete(@challenge_table, token)

  @spec put_invocation(binary(), map()) :: :ok
  def put_invocation(invoke_id, value) when is_binary(invoke_id) and is_map(value),
    do: Store.put(@invocation_table, invoke_id, value)

  @spec get_invocation(binary()) :: map() | nil
  def get_invocation(invoke_id) when is_binary(invoke_id),
    do: Store.get(@invocation_table, invoke_id)
end
