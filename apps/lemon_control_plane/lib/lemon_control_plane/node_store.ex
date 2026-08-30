defmodule LemonControlPlane.NodeStore do
  @moduledoc """
  Typed wrapper for node pairing, durable metadata, name reservations,
  challenges, and invocations.
  """

  alias LemonCore.Store

  @pairing_table :nodes_pairing
  @pairing_code_table :nodes_pairing_by_code
  @registry_table :nodes_registry
  @name_table :nodes_by_name
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

  @doc "Reserves a trimmed durable node name for one node ID."
  @spec reserve_node_name(binary(), binary()) ::
          :ok | {:error, :invalid_name | {:name_taken, binary()} | term()}
  def reserve_node_name(name, node_id) when is_binary(name) and is_binary(node_id) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, :invalid_name}

      durable_name_taken?(name, node_id) ->
        {:error, {:name_taken, name}}

      true ->
        case Store.put_new(@name_table, name, node_id) do
          :ok ->
            :ok

          {:error, :exists} ->
            if Store.get(@name_table, name) == node_id,
              do: :ok,
              else: {:error, {:name_taken, name}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Releases a durable node-name reservation if it still belongs to the node."
  @spec release_node_name(binary() | nil, binary()) :: :ok
  def release_node_name(name, node_id) when is_binary(name) and is_binary(node_id) do
    name = String.trim(name)

    if name != "" and Store.get(@name_table, name) == node_id do
      Store.delete(@name_table, name)
    else
      :ok
    end
  end

  def release_node_name(_name, _node_id), do: :ok

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

  defp durable_name_taken?(name, node_id) do
    Enum.any?(list_nodes(), fn {existing_id, node} ->
      existing_id != node_id and node_name(node) == name
    end)
  end

  defp node_name(node) when is_map(node), do: Map.get(node, :name) || Map.get(node, "name")
end
