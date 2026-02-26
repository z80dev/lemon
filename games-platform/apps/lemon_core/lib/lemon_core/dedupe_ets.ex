defmodule LemonCore.Dedupe.Ets do
  @moduledoc """
  Simple TTL-based deduplication backed by ETS.

  Stores `{key, ts_ms}` entries in an ETS `:set` table, where `ts_ms` is the
  monotonic time (ms) when the key was marked.

  TTL semantics:
  - A key is considered "seen" if `now_ms - ts_ms <= ttl_ms`.
  - Expired entries are deleted on access (and can also be cleaned in bulk).
  """

  @type table :: :ets.tid() | atom()
  @type key :: term()

  @doc """
  Ensure the ETS table exists.

  If `table` is an atom, a named table is created.
  """
  @spec init(table(), keyword()) :: :ok
  def init(table, opts \\ []) do
    case :ets.info(table) do
      :undefined ->
        protection = Keyword.get(opts, :protection, :public)
        type = Keyword.get(opts, :type, :set)

        base =
          case table do
            name when is_atom(name) -> [type, protection, :named_table]
            _tid -> [type, protection]
          end

        # Concurrency flags are safe defaults for this use-case.
        extra =
          opts
          |> Keyword.get(:ets_opts, [])
          |> Kernel.++([read_concurrency: true, write_concurrency: true])

        _ = :ets.new(table, base ++ extra)
        :ok

      _info ->
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
  @spec seen?(table(), key(), integer()) :: boolean()
  def seen?(table, key, ttl_ms) when is_integer(ttl_ms) do
    now = now_ms()

    case :ets.lookup(table, key) do
      [{^key, ts_ms}] when is_integer(ts_ms) and now - ts_ms <= ttl_ms ->
        true

      [{^key, _ts_ms}] ->
        _ = :ets.delete(table, key)
        false

      _ ->
        false
    end
  rescue
    _ -> false
  end

  def seen?(_table, _key, _ttl_ms), do: false

  @doc """
  Combined check + mark operation.

  Returns `:seen` if the key is currently within TTL, otherwise marks it and returns `:new`.
  """
  @spec check_and_mark(table(), key(), integer()) :: :seen | :new
  def check_and_mark(table, key, ttl_ms) when is_integer(ttl_ms) do
    if seen?(table, key, ttl_ms) do
      :seen
    else
      _ = mark(table, key)
      :new
    end
  rescue
    _ ->
      # Be conservative: if anything goes wrong, prefer "seen" to avoid double-processing.
      :seen
  end

  def check_and_mark(_table, _key, _ttl_ms), do: :seen

  @doc """
  Best-effort cleanup of entries older than `ttl_ms`.
  """
  @spec cleanup_expired(table(), integer()) :: non_neg_integer()
  def cleanup_expired(table, ttl_ms) when is_integer(ttl_ms) do
    now = now_ms()

    :ets.foldl(
      fn
        {key, ts_ms}, acc when is_integer(ts_ms) and now - ts_ms > ttl_ms ->
          _ = :ets.delete(table, key)
          acc + 1

        _entry, acc ->
          acc
      end,
      0,
      table
    )
  rescue
    _ -> 0
  end

  def cleanup_expired(_table, _ttl_ms), do: 0

  defp now_ms do
    System.monotonic_time(:millisecond)
  end
end

