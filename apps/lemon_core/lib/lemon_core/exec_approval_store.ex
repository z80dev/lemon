defmodule LemonCore.ExecApprovalStore do
  @moduledoc """
  Typed wrapper for execution approval policy and lifecycle records.

  Terminal records retain only identity, a snapshot digest and the verified
  decision. Pending accessors exclude them; a completed ID cannot be reused
  while its receipt is retained.

  ## Receipt retention

  A terminal record replaces its pending record under the same key in one
  compare-and-swap, so an approval is never both unrecorded and unresolved.
  Every terminal record built by `terminal_record/1` carries an `:expires_at`
  stamp `receipt_retention_ms/0` in the future (24 hours unless
  `config :lemon_core, :exec_approval_receipt_retention_ms` sets another
  positive value), and the `LemonCore.Store` periodic sweep deletes it once that
  passes. After that, resolving the ID returns `{:error, :not_found}`, never a
  replayed receipt.

  ## Owner index

  `index_owner/2` records which approval IDs a run (`{:run, run_id}`) or native
  session (`{:session, session_id}`) requested, before the pending record is
  written. Run and session end read only that owner's entry, so their cost
  does not grow with unrelated approvals or retained receipts.
  """

  alias LemonCore.Store

  @global_policy_table :exec_approvals_policy
  @agent_policy_table :exec_approvals_policy_agent
  @session_policy_table :exec_approvals_policy_session
  @node_policy_table :exec_approvals_policy_node
  @global_policy_map_table :exec_approvals_policy_map
  @node_policy_map_table :exec_approvals_policy_node_map
  @pending_table :exec_approvals_pending

  @session_owners_table :exec_approval_session_owners
  @owner_index_table :exec_approval_owner_index

  @default_receipt_retention_ms 24 * 60 * 60 * 1000
  # Concurrent requests of one owner race on its index entry; each lost
  # compare-and-swap rereads it. Exhaustion fails closed.
  @index_attempts 16

  @doc false
  def put_session_owner(id, owner), do: Store.put(@session_owners_table, id, owner)

  @doc false
  def fetch_session_owners, do: Store.fetch_all(@session_owners_table)

  @doc false
  def delete_session_owner(id), do: Store.delete(@session_owners_table, id)

  @spec get_global_policy(term(), term()) :: map() | nil
  def get_global_policy(tool, action_hash),
    do: Store.get(@global_policy_table, {tool, action_hash})

  @spec put_global_policy(term(), term(), map()) :: :ok | {:error, term()}
  def put_global_policy(tool, action_hash, value),
    do: Store.put(@global_policy_table, {tool, action_hash}, value)

  @spec list_global_policies() :: list()
  def list_global_policies, do: Store.list(@global_policy_table)

  @doc "Read global tool/action approvals without interpreting store failure as none."
  @spec fetch_global_policies() :: {:ok, list()} | {:error, :store_unavailable}
  def fetch_global_policies, do: Store.fetch_all(@global_policy_table)

  @spec get_agent_policy(term(), term(), term()) :: map() | nil
  def get_agent_policy(agent_id, tool, action_hash),
    do: Store.get(@agent_policy_table, {agent_id, tool, action_hash})

  @spec put_agent_policy(term(), term(), term(), map()) :: :ok | {:error, term()}
  def put_agent_policy(agent_id, tool, action_hash, value),
    do: Store.put(@agent_policy_table, {agent_id, tool, action_hash}, value)

  @spec list_agent_policies() :: list()
  def list_agent_policies, do: Store.list(@agent_policy_table)

  @spec get_session_policy(term(), term(), term()) :: map() | nil
  def get_session_policy(session_key, tool, action_hash),
    do: Store.get(@session_policy_table, {session_key, tool, action_hash})

  @spec put_session_policy(term(), term(), term(), map()) :: :ok | {:error, term()}
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

  @doc "Read the global tool policy map; `{:ok, nil}` only when none is stored."
  @spec fetch_global_policy_map() :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch_global_policy_map, do: Store.fetch(@global_policy_map_table, :global)

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
  def get_pending(approval_id) when is_binary(approval_id) do
    case fetch_pending(approval_id) do
      {:ok, pending} -> pending
      {:error, _} -> nil
    end
  end

  @spec fetch_pending(binary()) :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch_pending(approval_id) when is_binary(approval_id) do
    case fetch_record(approval_id) do
      {:ok, %{resolution: _}} -> {:ok, nil}
      result -> result
    end
  end

  @doc "Strict owner read, including retained terminal resolution records."
  @spec fetch_record(binary()) :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch_record(approval_id) when is_binary(approval_id),
    do: Store.fetch(@pending_table, approval_id)

  @doc "Atomically replace the exact owner record, never an alternate invocation."
  @spec transition(binary(), map(), map()) :: :ok | {:error, term()}
  def transition(approval_id, expected, replacement)
      when is_binary(approval_id) and is_map(expected) and is_map(replacement),
      do: Store.compare_and_swap(@pending_table, approval_id, expected, replacement)

  @spec put_pending_new(binary(), map()) :: :ok | {:error, term()}
  def put_pending_new(approval_id, pending) when is_binary(approval_id) and is_map(pending),
    do: Store.put_new(@pending_table, approval_id, pending)

  @spec delete_pending(binary()) :: :ok
  def delete_pending(approval_id) when is_binary(approval_id),
    do: Store.delete(@pending_table, approval_id)

  @doc "How long terminal approval records are retained before the Store sweep deletes them."
  @spec receipt_retention_ms() :: pos_integer()
  def receipt_retention_ms do
    case Application.get_env(:lemon_core, :exec_approval_receipt_retention_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_receipt_retention_ms
    end
  end

  @doc "Wrap a resolution receipt as a terminal record with its retention stamp."
  @spec terminal_record(map()) :: %{resolution: map(), expires_at: integer()}
  def terminal_record(receipt) when is_map(receipt),
    do: %{resolution: receipt, expires_at: LemonCore.Clock.now_ms() + receipt_retention_ms()}

  @doc "Record that `owner` requested `approval_id`."
  @spec index_owner({:run | :session, binary()}, binary()) :: :ok | {:error, term()}
  def index_owner({kind, id} = owner, approval_id)
      when kind in [:run, :session] and is_binary(id) and is_binary(approval_id) do
    update_owner_index(owner, fn ids ->
      if approval_id in ids, do: ids, else: [approval_id | ids]
    end)
  end

  @doc "Strict read of the approval IDs indexed for `owner`."
  @spec fetch_owner_index({:run | :session, binary()}) ::
          {:ok, [binary()]} | {:error, :store_unavailable}
  def fetch_owner_index({kind, id} = owner) when kind in [:run, :session] and is_binary(id) do
    case Store.fetch(@owner_index_table, owner) do
      {:ok, nil} -> {:ok, []}
      {:ok, ids} when is_list(ids) -> {:ok, ids}
      {:ok, _malformed} -> {:error, :store_unavailable}
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  @doc "Remove `approval_ids` from `owner`'s index, deleting the entry once empty."
  @spec unindex_owner({:run | :session, binary()}, [binary()]) :: :ok | {:error, term()}
  def unindex_owner(_owner, []), do: :ok

  def unindex_owner({kind, id} = owner, approval_ids)
      when kind in [:run, :session] and is_binary(id) and is_list(approval_ids) do
    update_owner_index(owner, &(&1 -- approval_ids))
  end

  defp update_owner_index(owner, fun, attempts \\ @index_attempts)
  defp update_owner_index(_owner, _fun, 0), do: {:error, :conflict}

  defp update_owner_index(owner, fun, attempts) do
    with {:ok, current} <- Store.fetch(@owner_index_table, owner) do
      ids = if is_list(current), do: current, else: []

      result =
        case {current, fun.(ids)} do
          {_current, ^ids} when is_list(current) or ids == [] -> :ok
          {nil, next} -> Store.put_new(@owner_index_table, owner, next)
          {current, []} -> Store.compare_and_delete(@owner_index_table, owner, current)
          {current, next} -> Store.compare_and_swap(@owner_index_table, owner, current, next)
        end

      case result do
        {:error, lost} when lost in [:exists, :mismatch] ->
          update_owner_index(owner, fun, attempts - 1)

        other ->
          other
      end
    end
  end

  @doc "Strict read of every record, terminal ones included (startup reconciliation)."
  @spec fetch_records() :: {:ok, list()} | {:error, :store_unavailable}
  def fetch_records do
    case Store.fetch_all(@pending_table) do
      {:ok, rows} -> {:ok, rows}
      {:error, _} -> {:error, :store_unavailable}
    end
  end

  @spec list_pending() :: list()
  def list_pending do
    @pending_table
    |> Store.list()
    |> Enum.reject(fn {_id, record} -> match?(%{resolution: _}, record) end)
  end

  @doc "Read pending requests without interpreting store failure as no approvals."
  def fetch_pending_list do
    with {:ok, pending} <- Store.fetch_all(@pending_table) do
      {:ok, Enum.reject(pending, fn {_id, record} -> match?(%{resolution: _}, record) end)}
    end
  end
end
