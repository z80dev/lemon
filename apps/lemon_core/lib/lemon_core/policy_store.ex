defmodule LemonCore.PolicyStore do
  @moduledoc """
  The policy plane: per-session policy rows.

  A session row (`:session_policies`, keyed by session key) holds the
  session's model and thinking overrides and its tool-policy override.
  `sessions.patch` and the channel `/model` commands write it;
  `LemonCore.SessionLifecycle` deletes it with the session. Configuration
  supplies defaults; there is no agent, channel or global runtime policy row.

  Policy rows restrict execution, so reads fail closed: `{:ok, nil}` means the
  Store confirmed no row exists, and a backend error, call timeout or missing
  Store process is `{:error, :store_unavailable}`. Callers must reject the
  operation on that error rather than treat it as "no restriction".
  """

  alias LemonCore.Store

  @session_table :session_policies
  @max_update_attempts 8

  @type fetched :: {:ok, map() | nil} | {:error, :store_unavailable}

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
end
