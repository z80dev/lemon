defmodule LemonCore.Store.Backend do
  @moduledoc """
  Behaviour for pluggable storage backends.

  A backend provides key-value storage across multiple logical tables. It is the
  half of `LemonCore.Store` that persists: the store owns the process and
  serialises access, the backend owns the bytes. Backends are plain modules —
  they have no process, no supervision and no lifecycle beyond `c:init/1`.

  `LemonCore.Store.EtsBackend` (ephemeral), `LemonCore.Store.SqliteBackend`
  (durable) and `LemonCore.Store.JsonlBackend` (append-only files) are the
  built-ins.

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

  ## No teardown callback

  There is deliberately no `close/1`/`terminate/2`: `LemonCore.Store` never
  tells a backend it is going away, so a backend holding a connection or file
  handle must be able to lose it to process exit. `SqliteBackend.close/1`
  exists but is not part of this behaviour and is not called by the store.
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

  @typedoc """
  Backend-specific failure description. Not portable: log it, do not match on it.
  """
  @type error_reason :: term()

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
  Performs a non-mutating backend liveness check.

  Optional. Returns `{:ok, state}` when the backend can reach its storage and
  `{:error, reason}` when it cannot, without changing any stored data.
  Backends without a meaningful external resource may omit this callback; the
  store then reports the backend as unpingable rather than assuming health.
  """
  @callback ping(state()) :: {:ok, state()} | {:error, error_reason()}

  @doc """
  Learn a table's declared policy before it is used.

  Optional. Called with each `LemonCore.Store.Table` registered with the
  store, at the store's start and on later registrations. A backend honours
  the hints it can — the SQLite backend keeps `persistence: :ephemeral`
  tables in memory — and ignores the rest. Returns `{:ok, state}`.
  """
  @callback register_table(state(), LemonCore.Store.Table.t()) :: {:ok, state()}

  @optional_callbacks list_recent: 3, ping: 1, register_table: 2
end
