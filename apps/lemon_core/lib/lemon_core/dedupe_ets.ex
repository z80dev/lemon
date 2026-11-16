defmodule LemonCore.Dedupe.Ets do
  @moduledoc """
  Simple TTL-based deduplication backed by ETS.

  Stores `{key, ts_ms}` entries in an ETS `:set` table, where `ts_ms` is the
  monotonic time (ms) when the key was marked.

  Each named table belongs to a worker under `LemonCore.Dedupe.Supervisor`,
  not to the first caller. A worker restart recreates an empty cache; this is
  best-effort, in-memory deduplication, not durable idempotency.

  TTL semantics:
  - A key is considered "seen" if `now_ms - ts_ms <= ttl_ms`.
  - Expired entries are deleted on access (and can also be cleaned in bulk).
  - `:infinity` retains a claim until explicitly forgotten or its owner restarts.
  - `retain/4` extends confirmed receipts without reserving unconfirmed work.

  All operations access ETS directly. Durable idempotency (including email
  lease/CAS receipts) must use Store instead; this cache is not a substitute.
  """

  @type table :: :ets.tid() | atom()
  @type key :: term()

  @doc """
  Ensure the ETS table exists.

  Starts a supervised owner for a public named set with concurrent reads and
  writes. The `:lemon_core` application must be running.
  """
  @spec init(atom()) :: :ok
  def init(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        case DynamicSupervisor.start_child(
               LemonCore.Dedupe.Supervisor,
               {LemonCore.Dedupe.Owner, table}
             ) do
          {:ok, _owner} ->
            :ok

          :ignore ->
            # Another queued start already created the table. The supervisor
            # completes that owner's init before processing this request.
            :ok
        end

      _existing ->
        :ok
    end
  end

  @doc """
  Mark a key as seen.
  """
  @spec mark(table(), key()) :: :ok
  def mark(table, key) do
    :ets.insert(table, {key, now_ms()})
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Check whether a key has been seen within `ttl_ms`.

  Deletes expired entries.
  """
  @spec seen?(table(), key(), non_neg_integer() | :infinity) :: boolean()
  def seen?(table, key, ttl_ms) when is_integer(ttl_ms) or ttl_ms == :infinity do
    now = now_ms()

    case :ets.lookup(table, key) do
      [{^key, ts_ms}] when is_integer(ts_ms) and (ttl_ms == :infinity or now - ts_ms <= ttl_ms) ->
        true

      [{^key, ts_ms}] ->
        :ets.delete_object(table, {key, ts_ms})
        false

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def seen?(_table, _key, _ttl_ms), do: false

  @doc """
  Atomically claim a key using `:ets.insert_new/2`.

  Exactly one concurrent caller returns `:new` for an absent or expired key.
  Expiry removes only the observed entry, never a concurrent replacement.
  An unavailable table fails closed with `:seen`.
  """
  @spec check_and_mark(table(), key(), non_neg_integer() | :infinity) :: :seen | :new
  def check_and_mark(table, key, ttl_ms) when is_integer(ttl_ms) or ttl_ms == :infinity do
    now = now_ms()

    if :ets.insert_new(table, {key, now}) do
      :new
    else
      case :ets.lookup(table, key) do
        [{^key, ts_ms}]
        when is_integer(ts_ms) and (ttl_ms == :infinity or now - ts_ms <= ttl_ms) ->
          :seen

        [{^key, ts_ms}] ->
          :ets.delete_object(table, {key, ts_ms})
          check_and_mark(table, key, ttl_ms)

        [] ->
          check_and_mark(table, key, ttl_ms)
      end
    end
  rescue
    _ ->
      # Be conservative: if anything goes wrong, prefer "seen" to avoid double-processing.
      :seen
  end

  def check_and_mark(_table, _key, _ttl_ms), do: :seen

  @doc """
  Atomically retain a confirmed mark until at least `remaining_ms` from now.

  Existing live marks may be extended but never shortened. Returns `:new` only
  for the caller inserting an absent or expired mark. This is for confirmed
  receipts, not provisional inbound claims.
  """
  @spec retain(table(), key(), integer(), integer()) :: :new | :seen
  def retain(table, key, remaining_ms, ttl_ms) do
    timestamp = now_ms() + remaining_ms - ttl_ms
    retain_timestamp(table, key, timestamp, ttl_ms)
  rescue
    ArgumentError -> :seen
  end

  defp retain_timestamp(table, key, timestamp, ttl_ms) do
    if :ets.insert_new(table, {key, timestamp}) do
      :new
    else
      case :ets.lookup(table, key) do
        [{^key, previous}] ->
          cond do
            now_ms() - previous > ttl_ms ->
              :ets.delete_object(table, {key, previous})
              retain_timestamp(table, key, timestamp, ttl_ms)

            previous >= timestamp ->
              :seen

            true ->
              spec = [{{key, previous}, [], [{:const, {key, timestamp}}]}]

              if :ets.select_replace(table, spec) == 1,
                do: :seen,
                else: retain_timestamp(table, key, timestamp, ttl_ms)
          end

        [] ->
          retain_timestamp(table, key, timestamp, ttl_ms)
      end
    end
  end

  @doc "Remove a provisional marker after a definite rejection."
  def forget(table, key) do
    :ets.delete(table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Best-effort cleanup of entries older than `ttl_ms`.
  """
  @spec cleanup_expired(table(), integer()) :: non_neg_integer()
  def cleanup_expired(table, ttl_ms) when is_integer(ttl_ms) do
    now = now_ms()

    :ets.select_delete(table, [
      {{:_, :"$1"}, [{:is_integer, :"$1"}, {:<, :"$1", now - ttl_ms}], [true]}
    ])
  rescue
    _ -> 0
  end

  def cleanup_expired(_table, _ttl_ms), do: 0

  defp now_ms do
    System.monotonic_time(:millisecond)
  end
end
