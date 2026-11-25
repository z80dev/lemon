defmodule LemonCore.Store.Backend do
  @moduledoc """
  Behaviour for pluggable storage backends.

  A backend provides key-value storage across multiple logical tables. It is the
  half of `LemonCore.Store` that persists: the store owns the process and
  serialises access, the backend owns the bytes. Backends are plain modules —
  they have no process or supervision. The store owns their lifecycle through
  `c:init/1` and the optional `c:close/1`.

  `LemonCore.Store.EtsBackend` (ephemeral) and `LemonCore.Store.SqliteBackend`
  (durable) are the built-ins.

  ## Contract

  Beyond the callback signatures, implementations must hold to the following.
  `LemonPlatformTest.BackendCase` turns each rule into a test; run it against
  your backend rather than re-deriving the rules from the built-ins.

    * **State is threaded.** `c:init/1` returns opaque state and every other
      callback takes it and returns it — including the read paths, which return
      `{:ok, result, state}`. The store always uses the state it was last
      handed. A backend may keep its real data outside the state (ETS table
      references, a database connection), but must never require the caller to
      discard the returned state.

    * **Tables spring into existence.** `table` is any atom the caller chooses,
      possibly for the first time and possibly on a read. Reading an unknown
      table yields `nil`/`[]`; writing to one creates it. `c:init/1` cannot know
      the set of tables in advance.

    * **Reads are total.** `c:get/3` on a missing key is `{:ok, nil, state}`,
      never an error. A stored `nil` is therefore indistinguishable from an
      absent key through `c:get/3` — `c:list/2` is where the difference shows,
      and it must show there.

    * **Writes are idempotent, deletes are forgiving.** `c:put/4` overwrites
      silently; `c:delete/3` on an absent key succeeds. `c:put_new/4` is the
      only conditional write, and `{:exists, state}` must leave the stored value
      untouched — it is the store's compare-and-set primitive, which
      idempotency keys depend on.

    * **Terms round-trip.** Keys and values are Erlang terms: binaries
      (including non-ASCII), atoms, numbers, tuples, nested maps and lists must
      come back equal. Backends that serialise inherit their encoding's limits;
      pids, references and functions are not required to survive.

  ## Error reasons are backend-specific

  Every `{:error, reason}` in this behaviour types `reason` as `term()`, and
  that is the honest description: the built-in SQLite backend answers with
  `{:error, :sqlite_busy}` and `{:error, {:sqlite_init_failed, path, reason}}`,
  a Redis backend would answer with something else entirely. **Callers must not
  pattern-match on a reason to decide behaviour** — treat any `{:error, _}` as
  "this operation did not happen" and log the reason. If a portable
  classification (retryable vs fatal) is ever needed it has to be added to the
  behaviour first.

  ## Resource cleanup

  The store invokes optional `c:close/1` during orderly termination. Backends
  must still tolerate abrupt owner death, when termination callbacks cannot
  run. An unsuccessful `c:init/1` must release any resources it already opened.
  """

  @typedoc "Opaque backend state, threaded through every callback."
  @type state :: term()

  @typedoc "Logical table name. Any atom, chosen by the caller, created on demand."
  @type table :: atom()

  @typedoc "Any Erlang term the backend's encoding can round-trip."
  @type key :: term()

  @typedoc "Any Erlang term the backend's encoding can round-trip. May be `nil`."
  @type value :: term()

  @type opts :: keyword()

  @typedoc "Indexed retention predicate; timestamps strictly before the cutoff expire."
  @type sweep_field ::
          :expires_at | :introspection_timestamp | :inserted_at_ms | :started_at_ms
  @type sweep_cutoff :: -9_223_372_036_854_775_808..9_223_372_036_854_775_807
  @type sweep_predicate :: {sweep_field(), sweep_cutoff()}

  @typedoc """
  Backend-specific failure description. Not portable: log it, do not match on it.
  """
  @type error_reason :: term()

  @typedoc "Backend-defined handle for reads outside the Store process (`c:reader/1`)."
  @type reader :: term()

  @doc """
  Initialize the backend with the given options.

  Called once by `LemonCore.Store` at start-up with the configured
  `:backend_opts`. Returns `{:ok, state}` or `{:error, reason}`; an error takes
  the store down, so a backend that can degrade should prefer to start and fail
  individual operations.

  Options are backend-defined (`SqliteBackend` requires `:path`), and a backend
  must tolerate being initialized more than once against the same underlying
  storage — a durable backend is re-`init/1`ed after every restart.
  """
  @callback init(opts()) :: {:ok, state()} | {:error, error_reason()}

  @doc """
  Store a value under the given table and key, overwriting any existing value.

  Creates the table if it does not exist. Must not fail because the key or the
  table is new.
  """
  @callback put(state(), table(), key(), value()) :: {:ok, state()}

  @doc """
  Store a value only if the table/key does not already exist.

  Returns `{:ok, state}` when the value was written, `{:exists, state}` when a
  value was already present — in which case the existing value must be left
  exactly as it was. This is the store's only compare-and-set primitive.
  """
  @callback put_new(state(), table(), key(), value()) ::
              {:ok, state()} | {:exists, state()} | {:error, error_reason()}

  @doc """
  Retrieve a value by table and key.

  Returns `{:ok, value, state}`, where `value` is `nil` when the key is absent.
  An unknown table is not an error; it reads as empty. Because `nil` is also a
  storable value, `c:get/3` cannot distinguish "stored nil" from "absent" —
  use `c:list/2` when that distinction matters.
  """
  @callback get(state(), table(), key()) :: {:ok, value() | nil, state()}

  @doc """
  Delete a value by table and key.

  Succeeds whether or not the key (or the table) exists — deleting is
  idempotent.
  """
  @callback delete(state(), table(), key()) :: {:ok, state()}

  @doc """
  Deletes expired rows in one storage-engine operation for the given table.

  Optional. A backend that omits this capability receives no automatic retention
  sweeps; Store does not fall back to listing rows and deleting them individually.
  Returns the deleted count in one operation. Comparisons are strict integer
  timestamp `< cutoff`:

    * `:expires_at` reads only the value's atom `:expires_at` key.
    * `:introspection_timestamp` prefers an integer first element of a two-tuple
      row key, then the value's `:ts_ms || "ts_ms"` field.
    * `:inserted_at_ms` reads only the value's string `"inserted_at_ms"` key.
    * `:started_at_ms` prefers an integer atom field, then an integer string field.

  Missing and non-integer timestamps remain untouched. Cutoffs are signed
  64-bit millisecond timestamps; values remain arbitrary Erlang integers.
  Callers must evict matching cached rows after success, using the same predicate.
  """
  @callback sweep(state(), table(), sweep_predicate()) ::
              {:ok, non_neg_integer(), state()} | {:error, error_reason()}

  @doc """
  Conditionally deletes several exact snapshots as one backend operation.

  Implementations that cannot provide an all-or-nothing transaction must
  validate every snapshot first, delete in caller-provided order, and return
  the first failure. Callers can then place their durable execution fence last
  so a partial failure cannot authorize duplicate work.
  """
  @callback compare_and_delete_many(state(), [{table(), key(), value()}]) ::
              {:ok, state()} | {:error, :mismatch | error_reason(), state()}

  @doc """
  List all key-value pairs in a table.

  Returns `{:ok, [{key, value}], state}`, or `{:ok, [], state}` for a table that
  has never been written. Order is unspecified; callers that need an order sort
  for themselves. Keys explicitly stored as `nil` appear here with a `nil`
  value, which is what makes them distinguishable from absent keys.
  """
  @callback list(state(), table()) :: {:ok, [{key(), value()}], state()}

  @doc """
  List the most recent `limit` entries from a table, ordered by recency.

  This is an optional callback. Backends that support it can push ORDER BY +
  LIMIT into the storage engine (e.g. SQL) to avoid loading all rows into
  memory; the store falls back to `c:list/2` when it is not exported.

  Must return at most `limit` entries, each of which is a real entry of that
  table. "Recency" is the backend's own notion of write time — a backend with
  no such notion (an ETS table, say) may return any `limit` entries rather than
  refusing, since the caller asked for a bounded page rather than a guarantee.

  Returns `{:ok, [{key, value}], state}`.
  """
  @callback list_recent(state(), table(), pos_integer()) ::
              {:ok, [{key(), value()}], state()} | {:error, error_reason()}

  @doc """
  Returns a handle that any process may pass to `c:read_list/2`,
  `c:read_range/5` and `c:read_recent/3` while the Store keeps writing.

  Optional, together with `c:read_list/2`. When exported, the Store runs
  full-table and time-range reads in the calling process, so a large scan never
  holds up the Store's other callers; without it those reads run inside the
  Store process. A read through the handle must observe every write the backend
  acknowledged before the handle was requested, and must fail (never return a
  partial table) when it cannot read the complete result.
  """
  @callback reader(state()) :: reader()

  @doc "Like `c:list/2`, through a `c:reader/1` handle in the caller's process."
  @callback read_list(reader(), table()) ::
              {:ok, [{key(), value()}]} | {:error, error_reason()}

  @doc "List only keys, without fetching or decoding their values."
  @callback read_keys(reader(), table()) :: {:ok, [key()]} | {:error, error_reason()}

  @doc """
  Rows with a `range_timestamp/3` in `[from_ms, to_ms)`, plus untimed rows
  when `include_untimed` is true.

  Optional. A backend that indexes `:at_ms` reads only the matching rows; the
  Store filters `c:read_list/2` otherwise.
  """
  @callback read_range(reader(), table(), integer(), integer(), boolean()) ::
              {:ok, [{key(), value()}]} | {:error, error_reason()}

  @doc false
  def range_timestamp(table, key, value)

  def range_timestamp(table, key, _value) when table in [:usage_records, "usage_records"] do
    with true <- is_binary(key),
         {:ok, date} <- Date.from_iso8601(key) do
      Date.diff(date, ~D[1970-01-01]) * 86_400_000
    else
      _ -> nil
    end
  end

  def range_timestamp(_table, _key, %{at_ms: ms}) when is_integer(ms), do: ms
  def range_timestamp(_table, _key, _value), do: nil

  @doc "Like `c:list_recent/3`, through a `c:reader/1` handle in the caller's process."
  @callback read_recent(reader(), table(), pos_integer()) ::
              {:ok, [{key(), value()}]} | {:error, error_reason()}

  @doc """
  Performs a non-mutating backend liveness check.

  Optional. Returns `{:ok, state}` when the backend can reach its storage and
  `{:error, reason}` when it cannot, without changing any stored data.
  Backends without a meaningful external resource may omit this callback; the
  store then reports the backend as unpingable rather than assuming health.
  """
  @callback ping(state()) :: {:ok, state()} | {:error, error_reason()}

  @doc """
  Replaces a value only when the stored value equals `expected` (`===`), as
  one backend operation.

  Optional. A backend whose storage is shared between OS processes (such as
  one SQLite file) implements it so the comparison and the write cannot
  interleave with another process. Without it, the store compares and writes
  in two calls, which is atomic only within the store process. A missing key
  matches `expected == nil`.
  """
  @callback compare_and_swap(state(), table(), key(), value(), value()) ::
              {:ok, state()} | {:error, :mismatch | error_reason(), state()}

  @doc """
  Makes every completed write durable across a host crash.

  Optional. Returns `{:ok, state}` once all writes acknowledged so far are on
  stable storage, or `{:error, reason}` when that cannot be confirmed. Callers
  use it as a barrier before an irreversible step that depends on those
  writes; the store reports `:sync_unsupported` for backends that omit it.
  """
  @callback sync(state()) :: {:ok, state()} | {:error, error_reason()}

  @doc """
  Runs one serialized Store mutation with a transaction-level durability barrier.
  Optional; backends without it use `sync/1` after the mutation instead.
  The callback must restore its ordinary write mode even on failure.
  """
  @callback with_durability(state(), (-> term())) :: term()

  @doc "Confirms visible authority; transaction-durable backends need no additional barrier."
  @callback confirm_durable(state()) :: {:ok, state()} | {:error, error_reason()}

  @doc """
  Releases backend resources during orderly Store termination.

  Optional. This is not a durability barrier: callers requiring one must use
  `c:sync/1` before closing. Initialization failures must clean themselves up.
  """
  @callback close(state()) :: :ok | {:error, error_reason()}

  @doc """
  Whether data written through this backend survives a restart of the VM.

  Optional; a backend that omits it is not durable. A product that requires
  the `:durable_store` capability (`LemonCore.Capabilities`) refuses to boot
  when the default store's configured backend is not durable.
  """
  @callback durable?() :: boolean()

  @optional_callbacks list_recent: 3,
                      reader: 1,
                      read_list: 2,
                      read_keys: 2,
                      read_range: 5,
                      read_recent: 3,
                      ping: 1,
                      compare_and_delete_many: 2,
                      compare_and_swap: 5,
                      with_durability: 2,
                      confirm_durable: 1,
                      sync: 1,
                      sweep: 3,
                      close: 1,
                      durable?: 0
end
