defmodule LemonCore.Idempotency do
  @moduledoc """
  At-most-once execution keyed by `{scope, key}`.

  Entries live in `LemonCore.IdempotencyStore` and move through two states:

    * `pending` — a caller won the key with an atomic `Store.put_new/4` and is
      executing. Other callers see the key in progress; they never execute.
    * `done` — the winner recorded its result by compare-and-swap from its own
      pending entry. Later callers receive that result.

  Done entries expire after 24 hours (wall clock); an expired entry is
  replaced by compare-and-swap, so two callers cannot both take it over.

  A pending entry never expires and is never swept: it carries no
  `"inserted_at_ms"`, the field the Store's retention sweep keys on. Its owner
  may have crashed, or its outcome may be unknown, so the operation may already
  have run or may still be running. It holds the key, with its original
  metadata, until authoritative reconciliation calls `complete/2` (the
  operation happened) or `release/1` (it provably never did) on the claim that
  `begin/3` returns. It is never retried automatically.

  Reads are strict. When the Store cannot answer, the result is
  `{:error, :store_unavailable}` and nothing executes: an unreadable key is
  never a miss.

  ## Examples

      LemonCore.Idempotency.execute("messages", "msg_abc123", fn -> send_message() end)
      #=> {:ok, result} | {:error, :in_progress} | {:error, :store_unavailable}

  Callers that must distinguish a definite failure (safe to retry) from an
  unknown outcome use `begin/3`, then `complete/2` or `release/1`.
  """

  alias LemonCore.IdempotencyStore

  @type scope :: term()
  @type key :: term()
  @type result :: term()
  @opaque claim :: %{scope: scope(), key: key(), entry: map()}

  # 24 hours
  @default_ttl_ms 24 * 60 * 60 * 1000
  @max_takeover_attempts 4

  @doc """
  Get the recorded result for a scope and key.

  Returns `{:ok, result}`, `:miss` when the Store confirms no live entry,
  `{:error, :in_progress}` while another caller holds the key, or
  `{:error, :store_unavailable}` when the Store cannot answer.
  """
  @spec get(scope(), key()) ::
          {:ok, result()} | :miss | {:error, :in_progress | :store_unavailable}
  def get(scope, key) do
    case IdempotencyStore.fetch(scope, key) do
      {:ok, nil} ->
        :miss

      {:ok, entry} ->
        cond do
          expired?(entry) -> :miss
          pending?(entry) -> {:error, :in_progress}
          true -> {:ok, result(entry)}
        end

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  @doc """
  Record a completed result, replacing any existing entry.

  Use `put_new/3`, `begin/3` or `execute/3` when the key must be claimed once.
  """
  @spec put(scope(), key(), result()) :: :ok | {:error, term()}
  def put(scope, key, result), do: IdempotencyStore.put(scope, key, done(result))

  @doc """
  Record a completed result only if no live entry exists for the key.

  Atomic: of concurrent callers exactly one gets `:ok`. Returns `:exists` when
  a live entry (pending or done) holds the key, or `{:error, :store_unavailable}`.
  """
  @spec put_new(scope(), key(), result()) :: :ok | :exists | {:error, :store_unavailable}
  def put_new(scope, key, result) do
    case insert(scope, key, done(result), @max_takeover_attempts) do
      :ok -> :ok
      {:exists, _entry} -> :exists
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  @doc "Delete an idempotency entry."
  @spec delete(scope(), key()) :: :ok | {:error, term()}
  def delete(scope, key), do: IdempotencyStore.delete(scope, key)

  @doc """
  Claim the key before performing a side effect.

  Returns `{:new, claim}` to the single winner, `{:done, result}` when a
  completed result exists, `{:pending, claim}` while an unresolved claim holds
  the key, or `{:error, :store_unavailable}` when the claim cannot be
  established. Only the `{:new, claim}` caller may perform the side effect.

  A `{:pending, claim}` is the existing claim, however old: `meta/1` returns
  the metadata its owner stored (for example a fixed run ID), and a caller that
  reconciles the operation authoritatively may `complete/2` or `release/1` it.
  """
  @spec begin(scope(), key(), term()) ::
          {:new, claim()}
          | {:done, result()}
          | {:pending, claim()}
          | {:error, :store_unavailable}
  def begin(scope, key, meta \\ nil) do
    entry = %{
      "state" => "pending",
      "claim" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "meta" => meta,
      "claimed_at_ms" => LemonCore.Event.now_ms()
    }

    case insert(scope, key, entry, @max_takeover_attempts) do
      :ok ->
        {:new, %{scope: scope, key: key, entry: entry}}

      {:exists, existing} ->
        if pending?(existing),
          do: {:pending, %{scope: scope, key: key, entry: existing}},
          else: {:done, result(existing)}

      {:error, _reason} ->
        # The claim write may have landed. Nothing executed, so removing our
        # own claim is safe; if this cleanup also fails the claim stays
        # pending until reconciled.
        _ = IdempotencyStore.compare_and_delete(scope, key, entry)
        {:error, :store_unavailable}
    end
  end

  @doc "The metadata stored with a claim by `begin/3`."
  @spec meta(claim()) :: term()
  def meta(%{entry: entry}), do: Map.get(entry, "meta")

  @doc """
  Record the claimed operation's result.

  A compare-and-swap from the claim's exact pending entry; `{:error, reason}`
  leaves the key pending (never executable again until reconciled).
  """
  @spec complete(claim(), result()) :: :ok | {:error, term()}
  def complete(%{scope: scope, key: key, entry: entry}, result) do
    IdempotencyStore.compare_and_swap(scope, key, entry, done(result))
  end

  @doc """
  Release a claim whose operation definitely did not happen, so the key can be
  used again. Never release after an unknown outcome.
  """
  @spec release(claim()) :: :ok | {:error, term()}
  def release(%{scope: scope, key: key, entry: entry}),
    do: IdempotencyStore.compare_and_delete(scope, key, entry)

  @doc """
  Execute `fun` at most once for the key.

  Returns `{:ok, result}` with this call's or the recorded result,
  `{:error, :in_progress}` while another claim holds the key, or
  `{:error, :store_unavailable}` when the key cannot be read or claimed (then
  `fun` is not called). If `fun` raises or exits, its claim stays pending until
  reconciled, because its side effects are unknown.
  """
  @spec execute(scope(), key(), (-> result())) ::
          {:ok, result()} | {:error, :in_progress | :store_unavailable}
  def execute(scope, key, fun) when is_function(fun, 0) do
    case begin(scope, key) do
      {:new, claim} ->
        result = fun.()
        _ = complete(claim, result)
        {:ok, result}

      {:done, result} ->
        {:ok, result}

      {:pending, _claim} ->
        {:error, :in_progress}

      {:error, _reason} = error ->
        error
    end
  end

  # Inserts `entry` unless a live entry holds the key; an expired done entry is
  # replaced by compare-and-swap against the exact expired value. A pending
  # entry is never expired.
  defp insert(_scope, _key, _entry, 0), do: {:error, :contended}

  defp insert(scope, key, entry, attempts) do
    case IdempotencyStore.put_new(scope, key, entry) do
      :ok ->
        :ok

      {:error, :exists} ->
        case IdempotencyStore.fetch(scope, key) do
          {:ok, nil} ->
            insert(scope, key, entry, attempts - 1)

          {:ok, existing} ->
            if expired?(existing),
              do: take_over(scope, key, existing, entry, attempts),
              else: {:exists, existing}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp take_over(scope, key, expired, entry, attempts) do
    case IdempotencyStore.compare_and_swap(scope, key, expired, entry) do
      :ok -> :ok
      {:error, :mismatch} -> insert(scope, key, entry, attempts - 1)
      {:error, _reason} = error -> error
    end
  end

  defp done(result),
    do: %{"state" => "done", "result" => result, "inserted_at_ms" => LemonCore.Event.now_ms()}

  defp pending?(%{"state" => "pending"}), do: true
  defp pending?(_entry), do: false

  # Entries written before the state field are completed results; the oldest
  # format stored the bare result.
  defp result(%{"result" => result, "inserted_at_ms" => _}), do: result
  defp result(legacy), do: legacy

  # Only completed results expire; an unresolved claim holds its key until
  # reconciled.
  defp expired?(%{"state" => "pending"}), do: false

  defp expired?(%{"inserted_at_ms" => inserted_at_ms}) when is_integer(inserted_at_ms),
    do: LemonCore.Event.now_ms() - inserted_at_ms > @default_ttl_ms

  defp expired?(_legacy), do: false
end
