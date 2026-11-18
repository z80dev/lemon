defmodule LemonCore.PolicyStore do
  @moduledoc """
  Agent, channel, session, and runtime policy persistence.

  Each scope has its own durable table (`:agent_policies`,
  `:channel_policies`, `:session_policies`); the operator's global runtime
  override lives under the `:global` key of `:runtime_policy`.

  Policy rows restrict execution, so reads fail closed: `{:ok, nil}` means the
  Store confirmed no row exists, and a backend error, call timeout or missing
  Store process is `{:error, :store_unavailable}`. Callers must reject the
  operation on that error rather than treat it as "no restriction".
  """

  alias LemonCore.Store

  @agent_table :agent_policies
  @channel_table :channel_policies
  @session_table :session_policies
  @runtime_table :runtime_policy
  @runtime_key :global
  @max_update_attempts 8

  @type fetched :: {:ok, map() | nil} | {:error, :store_unavailable}

  @doc "Fetches the policy for the given agent; `{:ok, nil}` only when none is stored."
  @spec fetch_agent(binary()) :: fetched()
  def fetch_agent(agent_id), do: Store.fetch(@agent_table, agent_id)

  @doc "Stores a policy for the given agent."
  @spec put_agent(binary(), map()) :: :ok | {:error, term()}
  def put_agent(agent_id, policy), do: Store.put(@agent_table, agent_id, policy)

  @doc "Fetches the policy for the given channel; `{:ok, nil}` only when none is stored."
  @spec fetch_channel(binary()) :: fetched()
  def fetch_channel(channel_id), do: Store.fetch(@channel_table, channel_id)

  @doc "Stores a policy for the given channel."
  @spec put_channel(binary(), map()) :: :ok | {:error, term()}
  def put_channel(channel_id, policy), do: Store.put(@channel_table, channel_id, policy)

  @doc "Fetches the policy for the given session; `{:ok, nil}` only when none is stored."
  @spec fetch_session(binary()) :: fetched()
  def fetch_session(session_key), do: Store.fetch(@session_table, session_key)

  @doc "Stores a policy for the given session."
  @spec put_session(binary(), map()) :: :ok | {:error, term()}
  def put_session(session_key, policy), do: Store.put(@session_table, session_key, policy)

  @doc """
  Atomically replaces the session row with `fun.(current)`.

  `current` is the strictly fetched row (`nil` when none is stored). The write
  is a compare-and-swap against that exact row, retried on a concurrent change,
  so a failed read can never overwrite fields this caller did not see. Returns
  the stored row, `{:error, :store_unavailable}` when the row cannot be read,
  or the Store's write error.
  """
  @spec update_session(binary(), (map() | nil -> map())) :: {:ok, map()} | {:error, term()}
  def update_session(session_key, fun) when is_function(fun, 1),
    do: update_session(session_key, fun, @max_update_attempts)

  defp update_session(_session_key, _fun, 0), do: {:error, :concurrent_update}

  defp update_session(session_key, fun, attempts) do
    with {:ok, current} <- fetch_session(session_key),
         updated when is_map(updated) <- fun.(current) do
      case Store.compare_and_swap(@session_table, session_key, current, updated) do
        :ok -> {:ok, updated}
        {:error, :mismatch} -> update_session(session_key, fun, attempts - 1)
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Deletes the policy for the given session."
  @spec delete_session(binary()) :: :ok | {:error, term()}
  def delete_session(session_key), do: Store.delete(@session_table, session_key)

  @doc "Fetches the runtime policy; `{:ok, nil}` only when none is stored."
  @spec fetch_runtime() :: fetched()
  def fetch_runtime, do: Store.fetch(@runtime_table, @runtime_key)

  @doc "Stores the runtime policy."
  @spec put_runtime(map()) :: :ok | {:error, term()}
  def put_runtime(policy), do: Store.put(@runtime_table, @runtime_key, policy)

  @doc "Deletes the runtime policy."
  @spec delete_runtime() :: :ok | {:error, term()}
  def delete_runtime, do: Store.delete(@runtime_table, @runtime_key)
end
