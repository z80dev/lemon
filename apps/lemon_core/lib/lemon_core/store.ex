defmodule LemonCore.Store do
  @moduledoc """
  Persistent key-value store with pluggable backends.

  ## Configuration

  Configure the backend in your application config:

      config :lemon_core, LemonCore.Store,
        backend: LemonCore.Store.SqliteBackend,
        backend_opts: [path: "/var/lib/lemon/store"]

  Defaults to `LemonCore.Store.EtsBackend` (in-memory, ephemeral).

  ## Instances

  A store is named; the default name is `LemonCore.Store` and every public
  function defaults to it, so single-store applications never pass a server.
  Several stores can run in one node:

      {LemonCore.Store, name: :scratch_store, backend: LemonCore.Store.EtsBackend}

      LemonCore.Store.put(:scratch_store, :notes, "k", "v")

  Configuration comes from `start_link/1` opts first (`:backend`,
  `:backend_opts`, `:cached_tables`, `:finalize_run_hooks`,
  `:runs_retention_ms`), falling back to
  `Application.get_env(:lemon_core, name)` — which for the default name is the
  historical `config :lemon_core, LemonCore.Store` block. Each instance gets its
  own `LemonCore.Store.ReadCache` tables.

  ## Collaborators

  This module is a storage primitive and deliberately knows nothing about chat
  state, policies, memory, chat platforms, or any other domain; typed owners
  such as `LemonCore.ChatStateStore` and `LemonCore.PolicyStore` sit on the
  generic table API, as do owners in other apps (gateway's progress index,
  channels' platform indices). Collaborators attach
  to it instead:

    * `:finalize_run_hooks` / `register_finalize_run_hook/2` — notified when any
      run is finalized, with or without a session key (see `finalize_run/3`).
    * `:cached_tables` / `register_cached_table/2` — generic tables to mirror
      into the read cache, for owners of hot indexes.

  See `LemonCore.Store.Hooks` for hook shapes and failure isolation.

  ## Expiring entries

  Values in `:chat` and `:exec_approvals_pending` (terminal approval receipts)
  that carry an integer `:expires_at` (epoch milliseconds) are removed by the
  periodic sweep once that time passes. Owners stamp the field; the store only
  enforces it.

  ## Client options

  One-shot client VMs (see `LemonCore.Application` boot modes) start the store
  with `sweep: false`, leaving sweeps to the runtime that owns the database.
  Writable clients add `defer_to_runtime: true`: a file-backed store starts
  refusing every mutation with `{:error, :runtime_owned}` and accepts writes
  only once the client's `LemonCore.RuntimeOwner` holds the database's
  ownership locks for the VM's lifetime (`claim_writes/1`). Beside a running
  runtime it never does, and the command must ask that runtime to write
  instead, so the client is never a second writer beside it. Read-only
  commands add `read_only: true`: every mutation returns
  `{:error, :read_only}`. Refused mutations never reach the backend, and
  run/introspection appends are dropped. `write_access/1` reports which applies.

  ## Run records and their retention

  `:runs` holds summary and lifecycle metadata only. `append_run_event/3`
  writes to a bounded per-run buffer (the first 200 and the latest events,
  2,000 in all). Finalization freezes the buffer until the run expires and
  passes its events to the durable history hook; late events are dropped.
  Only `get_run_with_events/2` attaches the buffer to a run read.

  Finalized runs are evicted by the periodic sweep `:runs_retention_ms`
  (default 24 hours) after finalization. Finalization also writes a small
  durable terminal marker to `:run_terminals` so `fetch_run/2` answers
  `{:error, :evicted}` for a finished run whose record is gone — including after
  a restart drops the ephemeral `:runs` table — instead of `{:ok, nil}`.
  Durable per-session history lives in `LemonCore.RunHistoryStore`.

  `:runs` is unbounded by nature, so `list/2`, `fetch_all/2`, `fetch_keys/2`
  and `fetch_range/5` refuse it; read runs by id.

  ## Reads outside the store process

  `fetch_all/2`, `fetch_keys/2`, `fetch_range/5`, `list/2` and
  `list_introspection_events/2` ask the store for a read handle (a short call
  that also orders the read after earlier writes) and then read the backend in
  the caller's process (`c:LemonCore.Store.Backend.reader/1`), so a large scan
  never stalls other store callers. Backends without a reader are read inside
  the store process.

  ## Read cache coherence

  `LemonCore.Store.ReadCache` mirrors hot tables into public ETS so reads skip
  this GenServer. The store process is the cache's **only** writer, and it
  writes only after the backend confirms, so the cache can never advertise a
  value the backend rejected. Consequences worth knowing:

    * A table is published as cached only once its warm-up read succeeded.
      A table whose warm-up failed stays uncached (reads reach the backend and
      surface its error) until the next start or `register_cached_table/2`.
    * Generic writes (`put/4`, `delete/3`, `compare_and_swap/5`, ...) are
      synchronous, so a read taken after one returns cannot observe the
      previous value.
    * `append_run_event/3` stays asynchronous, because runs stream events far
      more often than anything reads them back. A read taken before the cast
      drains can lag by a message. `ping/1` is the barrier when that matters.
    * `finalize_run/3` is synchronous: success means both the immutable final
      summary and its derived session index were written. A retry repairs a
      partial index failure without incrementing the session twice.
  """

  use GenServer

  alias LemonCore.MapHelpers
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.Hooks
  alias LemonCore.Store.ReadCache
  require Logger

  @default_backend EtsBackend
  # Sweep interval: 5 minutes in milliseconds
  @sweep_interval_ms 5 * 60 * 1000
  # Tables whose values may carry an `:expires_at` stamp for the periodic sweep.
  @expiring_tables [:chat, :exec_approvals_pending, :runs]
  # Tables too large to read whole; their owners read by key or range.
  @unscannable_tables [:runs]
  @default_runs_retention_ms 24 * 60 * 60 * 1000
  @run_terminals :run_terminals
  # Per-run event buffer bound: the first `@run_event_head` events and the
  # latest ones, `@run_event_limit` in all. Keep the moduledoc numbers in sync.
  @run_event_limit 2_000
  @run_event_head 200
  @default_introspection_retention_days 7
  @default_introspection_retention_ms @default_introspection_retention_days * 24 * 60 * 60 * 1000
  @default_introspection_query_limit 100
  @max_introspection_query_limit 1_000
  @store_call_timeout_ms 5_000
  # Generic tables mirrored into the read cache by default. Instances override
  # with `:cached_tables`; collaborators add their own with
  # `register_cached_table/2`.
  @default_cached_tables [:sessions_index, :chat]
  # How many recently indexed run ids each session index entry remembers so a
  # retried finalization does not count its run twice. Bounded on purpose: the
  # entry is copied on every cached read and rewritten on every finalization.
  @session_index_recent_runs 32

  @typedoc """
  A running store: its registered name (the usual case) or its pid.

  Read-cache fast paths are only available when addressing a store by name.
  """
  @type server :: atom() | pid()

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    unless is_atom(name) and not is_nil(name) do
      raise ArgumentError, "LemonCore.Store :name must be an atom, got: #{inspect(name)}"
    end

    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Where a running store keeps its data: `{backend, path}`, where `path` is the
  database file a file-backed backend actually opened, or `nil` for in-memory
  backends. Lets callers check durable coverage without reading config.
  """
  @spec location(server()) :: {module(), Path.t() | nil}
  def location(server \\ __MODULE__), do: GenServer.call(server, :location)

  @doc """
  The backend the default store is configured with (application env plus the
  runtime override), whether or not the store is running. Boot uses it to
  check the `:durable_store` capability before starting the store.
  """
  @spec configured_backend() :: module()
  def configured_backend do
    Keyword.get(resolve_config(__MODULE__, []), :backend, @default_backend)
  end

  @doc """
  Whether this store accepts mutations: `:ok`, `{:error, :read_only}` for a
  read-only client, or `{:error, :runtime_owned}` for a client beside a running
  runtime that owns the database (see "Client options").
  """
  @spec write_access(server()) :: :ok | {:error, :read_only | :runtime_owned}
  def write_access(server \\ __MODULE__), do: GenServer.call(server, :write_access)

  @doc false
  # Called by a client `LemonCore.RuntimeOwner` once it holds the ownership
  # locks; only a store started with `defer_to_runtime: true` starts writing.
  @spec claim_writes(server()) :: :ok
  def claim_writes(server \\ __MODULE__), do: GenServer.call(server, :claim_writes)

  # Run Events API

  @doc """
  Append an event to a live run's bounded event buffer (see "Run records and
  their retention"). Events for a finalized or evicted run are dropped.

  Asynchronous, because runs stream events far more often than anything reads
  them back, so a read taken before the cast drains can lag by a message;
  `ping/1` is the barrier when a caller needs the event to have landed.
  """
  @spec append_run_event(server(), term(), term()) :: :ok
  def append_run_event(server \\ __MODULE__, run_id, event) do
    GenServer.cast(server, {:append_run_event, run_id, event})
  end

  @doc """
  Record a run's summary and fire the store's finalize-run hooks.

  Every hook registered for this store (see `register_finalize_run_hook/2`) is
  invoked after successful finalization, regardless of session index eligibility:

      %{
        store: atom(),        # the store's name
        run_id: term(),
        record: map(),        # %{events: [...], summary: ..., started_at: ...}
        summary: map(),
        session_key: term(),  # nil when absent; only non-empty binaries are indexed
        started_at: integer()
      }

  Hooks run outside the Store in registration order, under a shared five-second
  caller-side budget. Failure or budget exhaustion is isolated from persistence.
  Hooks that require a session must ignore missing or invalid keys.

  Hook delivery is **at least once**. Hooks run after the run record and any
  eligible session index are written. Retries can invoke them again while the
  run record or a replay payload remains. Once only the terminal decision
  remains, an identical retry is acknowledged without running the hooks.
  Hook implementations must be idempotent by `run_id`.
  """
  @spec finalize_run(server(), term(), map()) :: :ok | {:error, term()}
  def finalize_run(server \\ __MODULE__, run_id, summary)

  def finalize_run(server, run_id, summary) when is_map(summary) do
    case safe_store_call(server, {:finalize_run, run_id, summary}, {:error, :store_unavailable},
           op: :finalize_run,
           table: :runs,
           key: run_id
         ) do
      {:finalized, hooks, payload} ->
        _ =
          case Hooks.invoke_bounded(hooks, payload, op: :finalize_run, store: server) do
            :ok -> update_terminal_effect(server, run_id, :projections, :done)
            {:error, _} -> update_terminal_effect(server, run_id, :projections, :failed)
          end

        :ok

      other ->
        other
    end
  end

  def finalize_run(_server, _run_id, _summary), do: {:error, :invalid_summary}

  @terminal_effect_retry_limit 8
  @terminal_pending :run_terminal_pending

  @doc false
  def terminal_effect_retry_limit, do: @terminal_effect_retry_limit

  @doc false
  def terminal_pending(server, run_id) do
    with {:ok, %{digest: digest}} <- fetch(server, @run_terminals, run_id),
         {:ok, row} <- fetch(server, @terminal_pending, run_id) do
      case row do
        %{digest: ^digest} -> {:ok, row}
        nil -> {:ok, nil}
        _ -> {:error, :invalid_terminal_payload}
      end
    end
  end

  @doc false
  def update_terminal_effect(server \\ __MODULE__, run_id, effect, status),
    do: update_terminal_effect(server, run_id, effect, status, 3)

  defp update_terminal_effect(_server, _run_id, _effect, _status, 0),
    do: {:error, :concurrent_update}

  defp update_terminal_effect(server, run_id, effect, status, remaining) do
    case terminal_pending(server, run_id) do
      {:ok, row} when is_map(row) ->
        replacement =
          case {Map.fetch!(row, effect), status} do
            {:done, _} -> row
            {_, :failed} -> row |> Map.put(effect, :failed) |> count_terminal_failure(effect)
            {_, :done} -> Map.put(row, effect, :done)
          end

        result =
          cond do
            Enum.all?([:notification, :projections, :presentation], &(replacement[&1] == :done)) ->
              compare_and_delete(server, @terminal_pending, run_id, row)

            replacement == row ->
              :ok

            true ->
              compare_and_swap(server, @terminal_pending, run_id, row, replacement, durable: true)
          end

        case result do
          {:error, :mismatch} ->
            update_terminal_effect(server, run_id, effect, status, remaining - 1)

          other ->
            other
        end

      {:ok, nil} ->
        :ok

      error ->
        error
    end
  end

  defp count_terminal_failure(row, effect) do
    counts = Map.get(row, :failures, %{})
    count = min(Map.get(counts, effect, 0) + 1, @terminal_effect_retry_limit)
    Map.put(row, :failures, Map.put(counts, effect, count))
  end

  # Generic Table API (for use by other lemon_* apps)

  @doc "Performs a non-mutating store/backend liveness check."
  @spec ping(server()) :: :ok | {:error, term()}
  def ping(server \\ __MODULE__) do
    safe_store_call(server, :ping, {:error, :store_unavailable},
      op: :ping,
      table: :store,
      key: :ping
    )
  end

  @doc """
  Durability barrier: returns `:ok` once every write acknowledged so far is on
  stable storage.

  Backends without `c:LemonCore.Store.Backend.sync/1` answer
  `{:error, :sync_unsupported}`, so callers that need durability fail closed.
  """
  @spec sync(server()) :: :ok | {:error, term()}
  def sync(server \\ __MODULE__) do
    safe_store_call(server, :sync, {:error, :store_unavailable},
      op: :sync,
      table: :store,
      key: :sync
    )
  end

  @doc """
  Confirms previously visible writes without forcing a SQLite checkpoint.
  SQLite durable transactions already committed with FULL; ordered backends
  still need their sync barrier before a visible row proves durable authority.
  """
  @spec confirm_durable(server()) :: :ok | {:error, term()}
  def confirm_durable(server \\ __MODULE__) do
    safe_store_call(server, :confirm_durable, {:error, :store_unavailable},
      op: :confirm_durable,
      table: :store,
      key: :confirm_durable
    )
  end

  @doc """
  Writes with a power-loss barrier before acknowledgement.

  Pass `durable: true` to the explicit-server mutation arities below. SQLite
  temporarily uses FULL synchronization for that transaction (F_FULLFSYNC on
  Darwin); ordinary writes remain NORMAL. Other backends use their sync barrier.
  A failed write/barrier is outcome-unknown, except confirmed exists/mismatch.
  Reads never need a checkpoint. `sync/1` remains the explicit drain seal.
  """
  @spec put(server(), atom(), term(), term(), keyword()) :: :ok | {:error, term()}
  def put(server, table, key, value, durable: true),
    do: durable_call(server, {:generic_put, table, key, value})

  @spec put_new(server(), atom(), term(), term(), keyword()) :: :ok | {:error, term()}
  def put_new(server, table, key, value, durable: true),
    do: durable_call(server, {:generic_put_new, table, key, value})

  @spec compare_and_swap(server(), atom(), term(), term(), term(), keyword()) ::
          :ok | {:error, term()}
  def compare_and_swap(server, table, key, expected, replacement, durable: true),
    do: durable_call(server, {:generic_compare_and_swap, table, key, expected, replacement})

  @spec delete(server(), atom(), term(), keyword()) :: :ok | {:error, term()}
  def delete(server, table, key, durable: true),
    do: durable_call(server, {:generic_delete, table, key})

  @spec compare_and_delete(server(), atom(), term(), term(), keyword()) :: :ok | {:error, term()}
  def compare_and_delete(server, table, key, expected, durable: true),
    do: durable_call(server, {:generic_compare_and_delete, table, key, expected})

  @spec compare_and_delete_many(server(), [{atom(), term(), term()}], keyword()) ::
          :ok | {:error, term()}
  def compare_and_delete_many(server, entries, durable: true),
    do: durable_call(server, {:generic_compare_and_delete_many, entries})

  @doc """
  Durable `take/3`: returns the removed value (or `nil`) only after the
  removal passed the durability barrier. A failed removal or barrier is
  `{:error, :outcome_unknown}`; callers consuming a single-use authority must
  treat it as not consumed and refuse to act.
  """
  @spec take(server(), atom(), term(), keyword()) :: term() | nil | {:error, term()}
  def take(server, table, key, durable: true),
    do: durable_call(server, {:generic_take, table, key})

  defp durable_call(server, request) do
    safe_store_call(server, {:durable_write, request}, {:error, :outcome_unknown},
      op: :durable_write,
      table: :store,
      key: :durable_write
    )
  end

  @doc """
  Put a value into a named table.

  This is a generic API for use by other apps (e.g., lemon_core, lemon_automation).
  """
  @spec put(server(), table :: atom(), key :: term(), value :: term()) ::
          :ok | {:error, term()}
  def put(server \\ __MODULE__, table, key, value) do
    safe_store_call(server, {:generic_put, table, key, value}, {:error, :store_unavailable},
      op: :put,
      table: table,
      key: key
    )
  end

  @doc """
  Put a value into a named table only if the key does not already exist.
  """
  @spec put_new(server(), table :: atom(), key :: term(), value :: term()) ::
          :ok | {:error, term()}
  def put_new(server \\ __MODULE__, table, key, value) do
    safe_store_call(server, {:generic_put_new, table, key, value}, {:error, :store_unavailable},
      op: :put_new,
      table: table,
      key: key
    )
  end

  @doc """
  Replaces a value only when its current value exactly matches `expected`.

  The read and write are serialized inside the Store process. When the backend
  exports `c:LemonCore.Store.Backend.compare_and_swap/5` (the SQLite backend
  does, in one `BEGIN IMMEDIATE` transaction) they are also atomic against
  other OS processes sharing the same storage. `nil` matches a missing key
  (and, like `get/3`, cannot distinguish a stored `nil`).
  """
  @spec compare_and_swap(server(), atom(), term(), term(), term()) ::
          :ok | {:error, :mismatch | term()}
  def compare_and_swap(server \\ __MODULE__, table, key, expected, replacement) do
    safe_store_call(
      server,
      {:generic_compare_and_swap, table, key, expected, replacement},
      {:error, :store_unavailable},
      op: :compare_and_swap,
      table: table,
      key: key
    )
  end

  @doc """
  Deletes a value only when its current value exactly matches `expected`.

  The comparison and delete are serialized inside the Store process. This is
  intended for sweepers and lease cleanup paths that must not erase a value
  changed after their earlier list or fetch snapshot.
  """
  @spec compare_and_delete(server(), atom(), term(), term()) ::
          :ok | {:error, :mismatch | term()}
  def compare_and_delete(server \\ __MODULE__, table, key, expected) do
    safe_store_call(
      server,
      {:generic_compare_and_delete, table, key, expected},
      {:error, :store_unavailable},
      op: :compare_and_delete,
      table: table,
      key: key
    )
  end

  @doc """
  Deletes several values only when every current value matches its snapshot.

  All comparisons and deletes run in one Store call, so another Store caller
  cannot renew one member between validation and deletion. Entries are
  `{table, key, expected}` tuples.
  """
  @spec compare_and_delete_many(server(), [{atom(), term(), term()}]) ::
          :ok | {:error, :mismatch | term()}
  def compare_and_delete_many(server \\ __MODULE__, entries) when is_list(entries) do
    safe_store_call(
      server,
      {:generic_compare_and_delete_many, entries},
      {:error, :store_unavailable},
      op: :compare_and_delete_many,
      table: :multiple,
      key: length(entries)
    )
  end

  @doc """
  Get a value from a named table.

  Returns `nil` if the key doesn't exist **or** the Store cannot answer
  (backend error, call timeout, missing process). Use it only for genuinely
  optional or display data; it is never an admission, policy, idempotency or
  verification check. Those use `fetch/3`.
  """
  @spec get(server(), table :: atom(), key :: term()) :: term() | nil
  def get(server \\ __MODULE__, table, key) do
    with true <- cached_table?(server, table),
         {:ok, value} <- ReadCache.fetch(server, table, key) do
      value
    else
      # Either the table is not mirrored or we missed. The store answers, and
      # populates its own cache on the way out when the table is mirrored — the
      # cache has a single writer, so a caller never publishes a value the
      # backend has not confirmed.
      _uncached_or_miss ->
        safe_store_call(server, {:generic_get, table, key}, nil, op: :get, table: table, key: key)
    end
  end

  @doc """
  Fetch a value without collapsing backend or process failure into absence.

  Unlike `get/3`, this returns `{:ok, nil}` only when the backend confirms that
  the key is absent. Correctness-sensitive admission paths should use this
  function when an unavailable read must fail closed.
  """
  @spec fetch(server(), table :: atom(), key :: term()) ::
          {:ok, term() | nil} | {:error, :store_unavailable}
  def fetch(server \\ __MODULE__, table, key) do
    with true <- cached_table?(server, table),
         {:ok, value} <- ReadCache.fetch(server, table, key) do
      {:ok, value}
    else
      _uncached_or_miss ->
        safe_store_call(
          server,
          {:generic_fetch, table, key},
          {:error, :store_unavailable},
          op: :fetch,
          table: table,
          key: key
        )
    end
  end

  @doc """
  Delete a key from a named table.
  """
  @spec delete(server(), table :: atom(), key :: term()) :: :ok | {:error, term()}
  def delete(server \\ __MODULE__, table, key) do
    safe_store_call(server, {:generic_delete, table, key}, {:error, :store_unavailable},
      op: :delete,
      table: table,
      key: key
    )
  end

  @doc """
  Atomically remove and return the value stored at `key` in a named table.

  Returns `nil` if the key doesn't exist. The read and the delete share one
  store call, so of N concurrent takers exactly one sees the value — the
  get-then-delete race between two `get/3` + `delete/3` callers cannot happen.
  A backend failure leaves the entry in place and returns `{:error, reason}`
  (or `{:error, :store_unavailable}` when the store itself is down), so a
  failed take is distinguishable from losing the race and never hands the
  value to more than one caller.
  """
  @spec take(server(), atom(), term()) :: term() | nil | {:error, term()}
  def take(server \\ __MODULE__, table, key) do
    safe_store_call(server, {:generic_take, table, key}, {:error, :store_unavailable},
      op: :take,
      table: table,
      key: key
    )
  end

  @doc """
  List all key-value pairs in a named table.

  Returns `[]` when the Store process is unavailable, but raises when a
  backend read fails rather than reporting an empty table. Use `fetch_all/2`
  to handle these failures explicitly. Raises `ArgumentError` for tables
  that cannot be read whole (`:runs`).
  """
  @spec list(server(), table :: atom()) :: [{term(), term()}]
  def list(server \\ __MODULE__, table) do
    ensure_scannable!(table)

    with true <- cached_table?(server, table),
         {:ok, entries} <- ReadCache.fetch_all(server, table) do
      entries
    else
      _uncached ->
        case read_outside_store(server, table, :list, :list) do
          {:ok, entries} -> entries
          {:error, :store_unavailable} -> []
          {:error, :backend_read_failed} -> raise "Store could not list #{inspect(table)}"
        end
    end
  end

  @doc """
  List all key-value pairs without collapsing backend or process failure.

  Unlike `list/2`, this always confirms the read with the owning Store process
  (ordering it after every write the Store acknowledged) and returns an error
  when the backend cannot confirm the complete table contents. The rows
  themselves are read in the caller's process when the backend supports it
  (see "Reads outside the store process"). Correctness-sensitive cleanup and
  migration paths should use this function before advancing durable sweep
  watermarks. Raises `ArgumentError` for tables that cannot be read whole
  (`:runs`).
  """
  @spec fetch_all(server(), table :: atom()) ::
          {:ok, [{term(), term()}]} | {:error, :store_unavailable}
  def fetch_all(server \\ __MODULE__, table) do
    ensure_scannable!(table)
    read_outside_store(server, table, :list, :fetch_all)
  end

  @doc false
  def terminal_pending_page(server, cursor, limit) do
    safe_store_call(
      server,
      {:terminal_pending_page, cursor, limit},
      {:error, :store_unavailable},
      op: :terminal_pending_page,
      table: :run_terminal_pending,
      key: :page
    )
  end

  @doc """
  Every key of a named table, strictly (like `fetch_all/2`).

  A mirrored table answers from its read cache without a Store call; otherwise
  the backend is read in the caller's process. Raises `ArgumentError` for
  tables that cannot be read whole (`:runs`).
  """
  @spec fetch_keys(server(), table :: atom()) :: {:ok, [term()]} | {:error, :store_unavailable}
  def fetch_keys(server \\ __MODULE__, table) do
    ensure_scannable!(table)

    with true <- cached_table?(server, table),
         {:ok, keys} <- ReadCache.fetch_keys(server, table) do
      {:ok, keys}
    else
      _uncached ->
        read_outside_store(server, table, :keys, :fetch_keys)
    end
  end

  @doc """
  Rows timed in `[from_ms, to_ms)`, strictly (like `fetch_all/2`).
  Most tables use the value's `:at_ms`; usage daily records use their date key.

  Backends that index `:at_ms` (SQLite) read only the matching rows, so a
  narrow window over a large table stays cheap. Pass `include_untimed: true`
  to also get the rows without an integer `:at_ms`, which no time window can
  exclude. Order is unspecified.
  """
  @spec fetch_range(server(), atom(), integer(), integer(), keyword()) ::
          {:ok, [{term(), term()}]} | {:error, :store_unavailable}
  def fetch_range(server, table, from_ms, to_ms, opts \\ [])
      when is_integer(from_ms) and is_integer(to_ms) and is_list(opts) do
    ensure_scannable!(table)
    query = {:range, from_ms, to_ms, Keyword.get(opts, :include_untimed, false) == true}
    read_outside_store(server, table, query, :fetch_range)
  end

  defp ensure_scannable!(table) when table in @unscannable_tables do
    raise ArgumentError,
          "LemonCore.Store table #{inspect(table)} cannot be read whole; read it by key"
  end

  defp ensure_scannable!(_table), do: :ok

  # Asks the store for a read handle — a short call that orders this read after
  # every write the store acknowledged — and reads the backend here, so a large
  # scan never blocks the store's other callers. Backends without a reader are
  # read inside the store process.
  defp read_outside_store(server, table, query, op) do
    case safe_store_call(server, :reader, {:error, :store_unavailable},
           op: op,
           table: table,
           key: :all
         ) do
      {:reader, backend, reader} ->
        read_with(backend, reader, table, query, op)

      :in_process ->
        request =
          case query do
            {:recent, limit} -> {:generic_list_recent, table, limit}
            :list when op == :list -> {:generic_list, table}
            _list_or_range -> {:generic_fetch_all, table}
          end

        with {:ok, entries} <-
               safe_store_call(server, request, {:error, :store_unavailable},
                 op: op,
                 table: table,
                 key: :all
               ) do
          {:ok, apply_read_query(entries, table, query)}
        end

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  defp read_with(backend, reader, table, query, op) do
    result =
      try do
        backend_read(backend, reader, table, query)
      rescue
        error -> {:error, {:reader_raised, error.__struct__}}
      catch
        kind, _reason -> {:error, {:reader_failed, kind}}
      end

    case result do
      {:ok, entries} when is_list(entries) ->
        {:ok, entries}

      {:error, reason} ->
        log_backend_error(op, table, :all, reason)
        read_failure(op)

      other ->
        log_backend_unexpected(op, table, :all, other)
        read_failure(op)
    end
  end

  defp read_failure(:list), do: {:error, :backend_read_failed}
  defp read_failure(_op), do: {:error, :store_unavailable}

  defp backend_read(backend, reader, table, :list), do: backend.read_list(reader, table)

  defp backend_read(backend, reader, table, :keys) do
    if function_exported?(backend, :read_keys, 2) do
      backend.read_keys(reader, table)
    else
      with {:ok, entries} <- backend.read_list(reader, table) do
        {:ok, apply_read_query(entries, table, :keys)}
      end
    end
  end

  defp backend_read(backend, reader, table, {:range, from_ms, to_ms, untimed} = query) do
    if function_exported?(backend, :read_range, 5) do
      backend.read_range(reader, table, from_ms, to_ms, untimed)
    else
      with {:ok, entries} <- backend.read_list(reader, table) do
        {:ok, apply_read_query(entries, table, query)}
      end
    end
  end

  defp backend_read(backend, reader, table, {:recent, limit}) do
    if function_exported?(backend, :read_recent, 3),
      do: backend.read_recent(reader, table, limit),
      else: backend.read_list(reader, table)
  end

  defp apply_read_query(entries, table, {:range, from_ms, to_ms, untimed}),
    do: EtsBackend.filter_range(entries, table, from_ms, to_ms, untimed)

  defp apply_read_query(entries, _table, :keys), do: Enum.map(entries, &elem(&1, 0))

  defp apply_read_query(entries, _table, _list_or_recent), do: entries

  # Whether this store mirrors `table` into the read cache. Read from the
  # store's published configuration so caller processes stay off the GenServer.
  defp cached_table?(server, table) when is_atom(server) and not is_nil(server) do
    table in Hooks.published(server, :cached_tables, [])
  end

  defp cached_table?(_server, _table), do: false

  @doc """
  Mirror `table` into this store's read cache from now on.

  Registration is remembered in supervised runtime ETS storage, so it survives
  a store restart and may be made before that store boots (after `:lemon_core`
  has started). Collaborators that own a generic table call this at startup:

      LemonCore.Store.register_cached_table(:my_hot_index)
  """
  @spec register_cached_table(atom(), atom()) :: :ok
  def register_cached_table(server \\ __MODULE__, table)
      when is_atom(server) and not is_nil(server) and is_atom(table) do
    Hooks.register(server, :cached_tables, table)

    if is_pid(GenServer.whereis(server)) do
      safe_store_call(server, {:register_cached_table, table}, :ok,
        op: :register_cached_table,
        table: table,
        key: :all
      )
    else
      :ok
    end
  end

  @doc "Stop mirroring `table`; takes effect on the store's next start."
  @spec unregister_cached_table(atom(), atom()) :: :ok
  def unregister_cached_table(server \\ __MODULE__, table) do
    Hooks.unregister(server, :cached_tables, table)
  end

  @doc """
  Register a hook invoked after each run is finalized with a session key.

  See `finalize_run/3` for the payload and `LemonCore.Store.Hooks` for the
  accepted hook shapes. Registration survives a store restart.
  """
  @spec register_finalize_run_hook(atom(), Hooks.hook()) :: :ok
  def register_finalize_run_hook(server \\ __MODULE__, hook) do
    Hooks.register(server, :finalize_run_hooks, hook)
  end

  @doc "Remove a previously registered finalize-run hook."
  @spec unregister_finalize_run_hook(atom(), Hooks.hook()) :: :ok
  def unregister_finalize_run_hook(server \\ __MODULE__, hook) do
    Hooks.unregister(server, :finalize_run_hooks, hook)
  end

  @doc """
  Get a specific run by ID, for display: `nil` when it is absent, evicted or
  the Store cannot answer. Does not attach buffered events.
  """
  @spec get_run(server(), term()) :: map() | nil
  def get_run(server \\ __MODULE__, run_id) do
    # Fast path: direct ETS cache lookup
    case ReadCache.get(server, :runs, run_id) do
      nil ->
        safe_store_call(server, {:get_run, run_id}, nil,
          op: :get_run,
          table: :runs,
          key: run_id
        )

      value ->
        value
    end
  end

  @doc """
  Fetch a specific run by ID without collapsing storage failures into absence.

  Use this at correctness boundaries where a missing run permits a mutation:
  `{:ok, nil}` means there is no run record or terminal fence,
  `{:error, :evicted}` means it was finalized and its record has since been
  evicted (treat it as finished), and `{:error, :store_unavailable}` preserves
  an unknown outcome when the backend cannot answer. Does not attach buffered events.
  """
  @spec fetch_run(server(), term()) ::
          {:ok, map() | nil} | {:error, :evicted | :store_unavailable}
  def fetch_run(server \\ __MODULE__, run_id) do
    case ReadCache.fetch(server, :runs, run_id) do
      {:ok, value} ->
        {:ok, value}

      _miss_or_uncached ->
        safe_store_call(server, {:fetch_run, run_id}, {:error, :store_unavailable},
          op: :fetch_run,
          table: :runs,
          key: run_id
        )
    end
  end

  @doc "Display read including retained events (newest first), or nil when absent."
  @spec get_run_with_events(server(), term()) :: map() | nil
  def get_run_with_events(server \\ __MODULE__, run_id),
    do: with_run_events(server, run_id, get_run(server, run_id))

  @doc false
  def fetch_session_runs(session_key, known_run_ids) do
    safe_store_call(
      __MODULE__,
      {:fetch_session_runs, session_key, known_run_ids},
      {:error, :store_unavailable},
      op: :fetch_session_runs,
      table: :runs,
      key: :session
    )
  end

  @doc false
  def discard_run_event_buffers([]), do: :ok

  def discard_run_event_buffers(run_ids) do
    safe_store_call(
      __MODULE__,
      {:discard_run_event_buffers, run_ids},
      {:error, :store_unavailable},
      op: :discard_run_event_buffers,
      table: :runs,
      key: :multiple
    )
  end

  defp with_run_events(server, run_id, record) when is_map(record) and is_atom(server) do
    case Hooks.published(server, :run_events, nil) do
      nil -> record
      buffer -> put_buffered_events(record, buffer, run_id)
    end
  end

  defp with_run_events(server, run_id, record) when is_map(record) and is_pid(server) do
    case Process.info(server, :registered_name) do
      {:registered_name, name} -> with_run_events(name, run_id, record)
      _ -> record
    end
  end

  defp with_run_events(_server, _run_id, record), do: record

  defp put_buffered_events(record, buffer, run_id) do
    case buffered_run_events(buffer, run_id) do
      {[], 0} -> Map.put_new(record, :events, [])
      {events, 0} -> Map.put(record, :events, events)
      {events, dropped} -> Map.merge(record, %{events: events, events_dropped: dropped})
    end
  rescue
    # The buffer died with a previous store process.
    ArgumentError -> record
  end

  # Newest first, like the record's historical `:events` list.
  defp buffered_run_events(buffer, run_id) do
    count = abs(:ets.lookup_element(buffer, {run_id, :seq}, 2, 0))

    events =
      reduce_buffer_seqs(count, [], fn seq, acc ->
        case :ets.lookup(buffer, {run_id, seq}) do
          [{_key, event}] -> [event | acc]
          [] -> acc
        end
      end)

    {events, max(count - @run_event_limit, 0)}
  end

  defp reduce_buffer_seqs(0, acc, _fun), do: acc

  defp reduce_buffer_seqs(count, acc, fun) when count <= @run_event_limit,
    do: Enum.reduce(1..count, acc, fun)

  defp reduce_buffer_seqs(count, acc, fun) do
    tail_start = count - (@run_event_limit - @run_event_head) + 1
    Enum.reduce(tail_start..count, Enum.reduce(1..@run_event_head, acc, fun), fun)
  end

  # Introspection Event API

  @doc """
  Append a canonical introspection event.
  """
  @spec append_introspection_event(server(), map()) :: :ok | {:error, term()}
  def append_introspection_event(server \\ __MODULE__, event)

  def append_introspection_event(server, event) when is_map(event) do
    # Validate required fields client-side so callers get immediate feedback
    # on malformed events without blocking on the GenServer.
    event_id = MapHelpers.get_key(event, :event_id)
    ts_ms = MapHelpers.get_key(event, :ts_ms)
    event_type = MapHelpers.get_key(event, :event_type)

    provenance = MapHelpers.get_key(event, :provenance) || :direct
    payload = MapHelpers.get_key(event, :payload) || %{}

    valid_id? = is_binary(event_id) and event_id != ""
    valid_ts? = is_integer(ts_ms) and ts_ms > 0

    valid_type? =
      (is_atom(event_type) and not is_nil(event_type)) or
        (is_binary(event_type) and event_type != "")

    valid_provenance? = provenance in [:direct, :inferred, :unavailable]
    valid_payload? = is_map(payload)

    if valid_id? and valid_ts? and valid_type? and valid_provenance? and valid_payload? do
      GenServer.cast(server, {:append_introspection_event, event})
      :ok
    else
      {:error, :invalid_introspection_event}
    end
  end

  def append_introspection_event(_server, _event), do: {:error, :invalid_introspection_event}

  @doc """
  List introspection events.

  ## Options

    * `:run_id` - Filter by run id
    * `:session_key` - Filter by session key
    * `:agent_id` - Filter by agent id
    * `:event_type` - Filter by event type
    * `:since_ms` - Include events at or after this timestamp
    * `:until_ms` - Include events at or before this timestamp
    * `:limit` - Maximum number of events to return (default: #{@default_introspection_query_limit})
  """
  @spec list_introspection_events(keyword()) :: [map()] | {:error, term()}
  def list_introspection_events(opts \\ []) when is_list(opts),
    do: list_introspection_events(__MODULE__, opts)

  @doc """
  List introspection events from a specific store instance.
  """
  @spec list_introspection_events(server(), keyword()) :: [map()] | {:error, term()}
  def list_introspection_events(server, opts) when is_list(opts) do
    limit =
      normalize_introspection_limit(Keyword.get(opts, :limit, @default_introspection_query_limit))

    # Without field filters a backend with `read_recent/3` pushes ORDER BY +
    # LIMIT into storage; otherwise every row is filtered here, outside the
    # store process.
    query = if introspection_opts_have_field_filters?(opts), do: :list, else: {:recent, limit}

    with {:ok, entries} <-
           read_outside_store(server, :introspection_log, query, :list_introspection_events) do
      entries
      |> Enum.map(fn {_key, event} -> event end)
      |> Enum.filter(&introspection_event_matches?(&1, opts))
      |> Enum.sort_by(&introspection_sort_key/1, :desc)
      |> Enum.take(limit)
    end
  end

  # A mutation whose call exited after it may have reached the store (timeout or
  # a crash mid-call) can still apply, so it is outcome-unknown, never a
  # definite failure. `:noproc`/`:shutdown` stay definite.
  @mutation_ops [
    :put,
    :put_new,
    :compare_and_swap,
    :compare_and_delete,
    :compare_and_delete_many,
    :delete,
    :take
  ]

  defp safe_store_call(server, request, fallback, context) do
    GenServer.call(server, request, @store_call_timeout_ms)
  catch
    :exit, reason ->
      reason = store_call_exit_reason(reason)

      Logger.warning(
        "Store client call failed store=#{inspect(server)} op=#{inspect(context[:op])} " <>
          "table=#{inspect(context[:table])} " <>
          "key=#{inspect(safe_log_key(context[:table], context[:key]))} " <>
          "reason=#{inspect(reason)}"
      )

      if context[:op] in @mutation_ops and reason not in [:noproc, :shutdown],
        do: {:error, :outcome_unknown},
        else: fallback
  end

  defp store_call_exit_reason({:timeout, {GenServer, :call, _}}), do: :timeout
  defp store_call_exit_reason({:noproc, {GenServer, :call, _}}), do: :noproc
  defp store_call_exit_reason({:shutdown, {GenServer, :call, _}}), do: :shutdown
  defp store_call_exit_reason(_), do: :exit

  # GenServer Implementation

  # Server-side only: called from `init/1` and the register-cached-table call,
  # both of which run in the store process. It lives below this line because
  # everything that touches the cache does.
  #
  # Returns the tables whose complete contents now sit in the cache. A table
  # whose backend read failed is left out: publishing it would make readers
  # trust an empty mirror, so it stays uncached and its reads hit the backend.
  defp warm_cached_tables(backend, backend_state, read_cache, tables) do
    Enum.reduce(tables, {backend_state, []}, fn table, {acc_state, warmed} ->
      case backend.list(acc_state, table) do
        {:ok, entries, next_state} ->
          Enum.each(entries, fn {key, value} ->
            ReadCache.put(read_cache, table, key, value)
          end)

          {next_state, warmed ++ [table]}

        {:error, reason} ->
          log_backend_error(:warm_cache, table, :all, reason)
          {acc_state, warmed}

        other ->
          log_backend_unexpected(:warm_cache, table, :all, other)
          {acc_state, warmed}
      end
    end)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    config = resolve_config(name, opts)

    # A previous incarnation's list names mirrors that died with it. Until this
    # one has warmed its own, readers must go to the backend.
    Hooks.publish(name, :cached_tables, [])

    backend = Keyword.get(config, :backend, @default_backend)
    backend_opts = Keyword.get(config, :backend_opts, [])
    finalize_run_hooks = List.wrap(Keyword.get(config, :finalize_run_hooks, []))

    configured_tables =
      Enum.uniq(
        List.wrap(Keyword.get(config, :cached_tables, @default_cached_tables)) ++
          Hooks.registered(name, :cached_tables)
      )

    case backend.init(backend_opts) do
      {:ok, backend_state} ->
        # Initialize this instance's read-through cache for high-traffic domains
        read_cache = ReadCache.init(name, configured_tables)

        {backend_state, cached_tables} =
          warm_cached_tables(backend, backend_state, read_cache, configured_tables)

        # Only tables that warmed are published, and only once they hold the
        # backend's contents: callers read this to decide whether to trust the
        # cache, and an unwarmed mirror would answer every read with nothing.
        Hooks.publish(name, :cached_tables, cached_tables)

        # Per-run event buffer: `{{run_id, seq}, event}` rows plus one
        # `{{run_id, :seq}, count}` counter per live run. Written only here;
        # readers resolve it from the published reference.
        run_events = :ets.new(:lemon_store_run_events, [:set, :protected, read_concurrency: true])
        run_events_expiry = :ets.new(:lemon_store_run_events_expiry, [:ordered_set, :private])
        Hooks.publish(name, :run_events, run_events)

        runs_retention_ms = positive_ms!(config, :runs_retention_ms, @default_runs_retention_ms)

        # Client VMs leave periodic sweeps to the runtime owning the database.
        _ = if Keyword.get(config, :sweep, true), do: schedule_sweep()
        write_refusal = write_refusal(config, backend_state)

        {:ok,
         %{
           name: name,
           read_cache: read_cache,
           cached_tables: cached_tables,
           finalize_run_hooks: finalize_run_hooks,
           backend: backend,
           backend_state: backend_state,
           run_events: run_events,
           run_events_expiry: run_events_expiry,
           runs_retention_ms: runs_retention_ms,
           introspection_retention_ms: @default_introspection_retention_ms,
           read_only: write_refusal != nil,
           write_refusal: write_refusal,
           defer_to_runtime: Keyword.get(config, :defer_to_runtime, false) == true
         }}

      {:error, reason} ->
        {:stop, {:backend_init_failed, reason}}
    end
  end

  # A writable client's file-backed store waits for its RuntimeOwner to hold
  # the database's ownership locks; an in-memory store cannot be shared.
  defp write_refusal(config, backend_state) do
    cond do
      Keyword.get(config, :read_only, false) == true ->
        :read_only

      Keyword.get(config, :defer_to_runtime, false) == true and
          match?(%{path: path} when is_binary(path), backend_state) ->
        :runtime_owned

      true ->
        nil
    end
  end

  # start_link opts win; anything absent falls back to the app env keyed by the
  # store's name (the historical `config :lemon_core, LemonCore.Store` block for
  # the default instance). The `:store_runtime_override` escape hatch is a
  # property of the default runtime store, so it is not applied to instances.
  defp resolve_config(name, opts) do
    env_config = Application.get_env(:lemon_core, name, [])

    env_config =
      if name == __MODULE__ do
        merge_runtime_override(
          env_config,
          Application.get_env(:lemon_core, :store_runtime_override, [])
        )
      else
        env_config
      end

    opts
    |> Keyword.take([
      :backend,
      :backend_opts,
      :cached_tables,
      :finalize_run_hooks,
      :sweep,
      :read_only,
      :runs_retention_ms,
      :defer_to_runtime
    ])
    |> then(&Keyword.merge(env_config, &1))
  end

  defp positive_ms!(config, key, default) do
    case Keyword.get(config, key, default) do
      ms when is_integer(ms) and ms > 0 ->
        ms

      other ->
        raise ArgumentError,
              "LemonCore.Store #{inspect(key)} must be a positive integer of milliseconds, " <>
                "got: #{inspect(other)}"
    end
  end

  # Deduplicated across both sources: a collaborator that is listed in config
  # *and* registers itself at boot is one hook, not two. Without this, wiring it
  # both ways silently ingests every finalized run twice.
  defp finalize_run_hooks(state) do
    Enum.uniq(state.finalize_run_hooks ++ Hooks.registered(state.name, :finalize_run_hooks))
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired, @sweep_interval_ms)
  end

  defp merge_runtime_override(config, []), do: config

  defp merge_runtime_override(config, override) when is_list(config) and is_list(override) do
    override_without_backend_opts = Keyword.delete(override, :backend_opts)
    merged = Keyword.merge(config, override_without_backend_opts)

    case Keyword.fetch(override, :backend_opts) do
      {:ok, override_backend_opts} ->
        backend_opts =
          Keyword.merge(Keyword.get(config, :backend_opts, []), override_backend_opts)

        Keyword.put(merged, :backend_opts, backend_opts)

      :error ->
        merged
    end
  end

  defp merge_runtime_override(config, _override), do: config

  # A read-only store (a read-only one-shot client, or a writable one beside a
  # running runtime) refuses every mutation before it reaches the backend, so it
  # is never a second writer.
  @read_only_refused [
    :generic_put,
    :generic_put_new,
    :generic_compare_and_swap,
    :generic_compare_and_delete,
    :generic_compare_and_delete_many,
    :generic_delete,
    :generic_take,
    :durable_write,
    :finalize_run,
    :discard_run_event_buffers
  ]

  @impl true
  def handle_call(request, _from, %{read_only: true} = state)
      when is_tuple(request) and elem(request, 0) in @read_only_refused,
      do: {:reply, {:error, state.write_refusal}, state}

  def handle_call(:write_access, _from, %{read_only: true} = state),
    do: {:reply, {:error, state.write_refusal}, state}

  def handle_call(:write_access, _from, state), do: {:reply, :ok, state}

  # The claimer holds the ownership locks; when it exits the store stops writing.
  def handle_call(
        :claim_writes,
        {claimer, _tag},
        %{defer_to_runtime: true, write_refusal: :runtime_owned} = state
      ) do
    Process.monitor(claimer)
    {:reply, :ok, %{state | read_only: false, write_refusal: nil}}
  end

  def handle_call(:claim_writes, _from, state), do: {:reply, :ok, state}

  def handle_call(:location, _from, state) do
    path =
      case state.backend_state do
        %{path: path} when is_binary(path) -> path
        _ -> nil
      end

    {:reply, {state.backend, path}, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    if function_exported?(state.backend, :ping, 1) do
      case state.backend.ping(state.backend_state) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          log_backend_error(:ping, :store, :ping, reason)
          {:reply, {:error, reason}, state}

        other ->
          log_backend_unexpected(:ping, :store, :ping, other)
          {:reply, {:error, {:unexpected_backend_response, other}}, state}
      end
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:register_cached_table, table}, _from, state) do
    if table in state.cached_tables do
      {:reply, :ok, state}
    else
      read_cache = ReadCache.add_table(state.name, state.read_cache, table)

      # A failed warm leaves the table unpublished; registering it again retries.
      {backend_state, warmed} =
        warm_cached_tables(state.backend, state.backend_state, read_cache, [table])

      cached_tables = state.cached_tables ++ warmed

      # Publish after warming, for the reason given in `init/1`.
      Hooks.publish(state.name, :cached_tables, cached_tables)

      {:reply, :ok,
       %{
         state
         | read_cache: read_cache,
           cached_tables: cached_tables,
           backend_state: backend_state
       }}
    end
  end

  def handle_call({:fetch_session_runs, session_key, known_run_ids}, _from, state) do
    # In addition to IDs in durable history or introspection, find hot
    # summaries that have already aged out of those projections. Do not copy
    # unrelated runs out of ETS.
    rows =
      :ets.select(state.read_cache.runs, [
        {{:_, %{summary: %{session_key: session_key}}}, [], [:"$_"]}
      ])

    result =
      Enum.reduce_while(known_run_ids, {:ok, Map.new(rows), state.backend_state}, fn
        id, {:ok, rows, _backend_state} = acc when is_map_key(rows, id) ->
          {:cont, acc}

        id, {:ok, rows, backend_state} ->
          case backend_get(state, backend_state, :runs, id) do
            {:ok, nil, backend_state} -> {:cont, {:ok, rows, backend_state}}
            {:ok, row, backend_state} -> {:cont, {:ok, Map.put(rows, id, row), backend_state}}
            {:error, _} = error -> {:halt, error}
          end
      end)

    case result do
      {:ok, rows, backend_state} -> {:reply, {:ok, rows}, %{state | backend_state: backend_state}}
      {:error, _} -> {:reply, {:error, :store_unavailable}, state}
    end
  end

  def handle_call({:discard_run_event_buffers, run_ids}, _from, state) do
    Enum.each(run_ids, &drop_run_events(state, &1))
    {:reply, :ok, state}
  end

  def handle_call({:get_run, run_id}, _from, state) do
    case state.backend.get(state.backend_state, :runs, run_id) do
      {:ok, value, backend_state} ->
        {:reply, value, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:get, :runs, run_id, reason)
        {:reply, nil, state}

      other ->
        log_backend_unexpected(:get, :runs, run_id, other)
        {:reply, nil, state}
    end
  end

  def handle_call({:fetch_run, run_id}, _from, state) do
    case backend_get(state, state.backend_state, :runs, run_id) do
      {:ok, nil, backend_state} ->
        case backend_get(state, backend_state, @run_terminals, run_id) do
          {:ok, nil, backend_state} ->
            {:reply, {:ok, nil}, %{state | backend_state: backend_state}}

          {:ok, _tombstone, backend_state} ->
            {:reply, {:error, :evicted}, %{state | backend_state: backend_state}}

          {:error, _reason} ->
            {:reply, {:error, :store_unavailable}, state}
        end

      {:ok, record, backend_state} ->
        ReadCache.put(state.read_cache, :runs, run_id, record)
        {:reply, {:ok, record}, %{state | backend_state: backend_state}}

      {:error, _reason} ->
        {:reply, {:error, :store_unavailable}, state}
    end
  end

  def handle_call({:terminal_pending_page, cursor, limit}, _from, state) do
    table = :run_terminal_pending

    result =
      if function_exported?(state.backend, :list_page, 4) do
        state.backend.list_page(state.backend_state, table, cursor, limit)
      else
        with {:ok, entries, backend_state} <- state.backend.list(state.backend_state, table) do
          page =
            entries
            |> Enum.filter(fn {key, _} -> is_nil(cursor) or key > cursor end)
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.take(limit)

          {:ok, page, backend_state}
        end
      end

    case result do
      {:ok, entries, backend_state} ->
        {:reply, {:ok, entries}, %{state | backend_state: backend_state}}

      _ ->
        {:reply, {:error, :store_unavailable}, state}
    end
  end

  def handle_call({:finalize_run, run_id, summary}, _from, state) do
    {reply, state} = finalize_run_record(state, run_id, summary)
    {:reply, reply, state}
  end

  # A read handle for `read_outside_store/4`. The call itself is the ordering
  # barrier: the handle sees every write acknowledged before it.
  def handle_call(:reader, _from, state) do
    if function_exported?(state.backend, :reader, 1) and
         function_exported?(state.backend, :read_list, 2) do
      {:reply, {:reader, state.backend, state.backend.reader(state.backend_state)}, state}
    else
      {:reply, :in_process, state}
    end
  end

  def handle_call({:generic_put, table, key, value}, _from, state) do
    case state.backend.put(state.backend_state, table, key, value) do
      {:ok, backend_state} ->
        if table in state.cached_tables do
          ReadCache.put(state.read_cache, table, key, value)
        end

        {:reply, :ok, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:put, table, key, reason)
        {:reply, {:error, reason}, state}

      other ->
        log_backend_unexpected(:put, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  def handle_call({:generic_put_new, table, key, value}, _from, state) do
    case state.backend.put_new(state.backend_state, table, key, value) do
      {:ok, backend_state} ->
        if table == :runs or table in state.cached_tables do
          ReadCache.put(state.read_cache, table, key, value)
        end

        {:reply, :ok, %{state | backend_state: backend_state}}

      {:exists, backend_state} ->
        {:reply, {:error, :exists}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:put_new, table, key, reason)
        {:reply, {:error, reason}, state}

      other ->
        log_backend_unexpected(:put_new, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  def handle_call({:generic_compare_and_swap, table, key, expected, replacement}, _from, state) do
    if function_exported?(state.backend, :compare_and_swap, 5) do
      backend_compare_and_swap(state, table, key, expected, replacement)
    else
      store_compare_and_swap(state, table, key, expected, replacement)
    end
  end

  def handle_call({:durable_write, request}, from, state) do
    result =
      if function_exported?(state.backend, :with_durability, 2) do
        state.backend.with_durability(state.backend_state, fn ->
          handle_call(request, from, state)
        end)
      else
        case handle_call(request, from, state) do
          {:reply, :ok, next_state} ->
            handle_call(:sync, from, next_state)

          # A take replies with the removed value; it is durable only once
          # the barrier after the removal succeeds.
          {:reply, value, next_state}
          when elem(request, 0) == :generic_take and
                 not (is_tuple(value) and elem(value, 0) == :error) ->
            case handle_call(:sync, from, next_state) do
              {:reply, :ok, synced} -> {:reply, value, synced}
              other -> other
            end

          other ->
            other
        end
      end

    case result do
      {:reply, {:error, reason}, next_state} when reason not in [:exists, :mismatch] ->
        {:reply, {:error, :outcome_unknown}, next_state}

      other ->
        other
    end
  end

  def handle_call(operation, _from, state) when operation in [:sync, :confirm_durable] do
    callback =
      if operation == :confirm_durable and function_exported?(state.backend, :confirm_durable, 1),
        do: :confirm_durable,
        else: :sync

    if function_exported?(state.backend, callback, 1) do
      case apply(state.backend, callback, [state.backend_state]) do
        {:ok, backend_state} ->
          {:reply, :ok, %{state | backend_state: backend_state}}

        {:error, reason} ->
          log_backend_error(:sync, :store, :sync, reason)
          {:reply, {:error, reason}, state}

        other ->
          log_backend_unexpected(:sync, :store, :sync, other)
          {:reply, {:error, {:unexpected_backend_response, other}}, state}
      end
    else
      {:reply, {:error, :sync_unsupported}, state}
    end
  end

  def handle_call({:generic_compare_and_delete, table, key, expected}, _from, state) do
    case state.backend.get(state.backend_state, table, key) do
      {:ok, current, backend_state} when current === expected ->
        case state.backend.delete(backend_state, table, key) do
          {:ok, backend_state} ->
            if table in state.cached_tables do
              ReadCache.delete(state.read_cache, table, key)
            end

            {:reply, :ok, %{state | backend_state: backend_state}}

          {:error, reason} ->
            log_backend_error(:compare_and_delete, table, key, reason)
            {:reply, {:error, reason}, %{state | backend_state: backend_state}}

          other ->
            log_backend_unexpected(:compare_and_delete, table, key, other)

            {:reply, {:error, {:unexpected_backend_response, other}},
             %{state | backend_state: backend_state}}
        end

      {:ok, _current, backend_state} ->
        {:reply, {:error, :mismatch}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:compare_and_delete, table, key, reason)
        {:reply, {:error, reason}, state}

      other ->
        log_backend_unexpected(:compare_and_delete, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  def handle_call({:generic_compare_and_delete_many, entries}, _from, state) do
    result =
      if function_exported?(state.backend, :compare_and_delete_many, 2) do
        state.backend.compare_and_delete_many(state.backend_state, entries)
      else
        compare_and_delete_many_fallback(state.backend, state.backend_state, entries)
      end

    case result do
      {:ok, backend_state} ->
        invalidate_snapshot_cache(state, entries)
        {:reply, :ok, %{state | backend_state: backend_state}}

      {:error, reason, backend_state} ->
        # A non-transactional backend may have applied a safe prefix before
        # reporting failure. Invalidate every involved cache key so reads
        # reflect the backend's durable result.
        invalidate_snapshot_cache(state, entries)
        bounded_reason = bound_compare_and_delete_many_error(entries, reason)
        {:reply, {:error, bounded_reason}, %{state | backend_state: backend_state}}

      other ->
        log_compare_and_delete_many_unexpected(entries, other)
        {:reply, {:error, :unexpected_backend_response}, state}
    end
  end

  def handle_call({:generic_get, table, key}, _from, state) do
    case state.backend.get(state.backend_state, table, key) do
      {:ok, value, backend_state} ->
        # Populate the mirror on the way out, from the process that owns it.
        if not is_nil(value) and table in state.cached_tables do
          ReadCache.put(state.read_cache, table, key, value)
        end

        {:reply, value, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:get, table, key, reason)
        {:reply, nil, state}

      other ->
        log_backend_unexpected(:get, table, key, other)
        {:reply, nil, state}
    end
  end

  def handle_call({:generic_fetch, table, key}, _from, state) do
    case state.backend.get(state.backend_state, table, key) do
      {:ok, value, backend_state} ->
        if not is_nil(value) and table in state.cached_tables do
          ReadCache.put(state.read_cache, table, key, value)
        end

        {:reply, {:ok, value}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:fetch, table, key, reason)
        {:reply, {:error, :store_unavailable}, state}

      other ->
        log_backend_unexpected(:fetch, table, key, other)
        {:reply, {:error, :store_unavailable}, state}
    end
  end

  def handle_call({:generic_delete, table, key}, _from, state) do
    case state.backend.delete(state.backend_state, table, key) do
      {:ok, backend_state} ->
        if table in state.cached_tables do
          ReadCache.delete(state.read_cache, table, key)
        end

        {:reply, :ok, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:delete, table, key, reason)
        {:reply, {:error, reason}, state}

      other ->
        log_backend_unexpected(:delete, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  # Atomic delete-and-return: the get and the delete share this one store
  # call, so exactly one of N concurrent takers can observe the value. The
  # read-cache mirror is invalidated exactly like `:generic_delete`.
  def handle_call({:generic_take, table, key}, _from, state) do
    case state.backend.get(state.backend_state, table, key) do
      {:ok, nil, backend_state} ->
        {:reply, nil, %{state | backend_state: backend_state}}

      {:ok, value, backend_state} ->
        case state.backend.delete(backend_state, table, key) do
          {:ok, backend_state} ->
            if table in state.cached_tables do
              ReadCache.delete(state.read_cache, table, key)
            end

            {:reply, value, %{state | backend_state: backend_state}}

          {:error, reason} ->
            log_backend_error(:take, table, key, reason)
            # The entry survives a failed take: no caller was handed it, and
            # the error is distinguishable from `nil` "lost the race".
            {:reply, {:error, reason}, %{state | backend_state: backend_state}}

          other ->
            log_backend_unexpected(:take, table, key, other)

            {:reply, {:error, {:unexpected_backend_response, other}},
             %{state | backend_state: backend_state}}
        end

      {:error, reason} ->
        log_backend_error(:take, table, key, reason)
        {:reply, {:error, reason}, state}

      other ->
        log_backend_unexpected(:take, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  # The in-store reads for backends without a `reader/1`.
  def handle_call({:generic_list, table}, _from, state),
    do: reply_entries(state, :list, table, state.backend.list(state.backend_state, table))

  def handle_call({:generic_fetch_all, table}, _from, state),
    do: reply_entries(state, :fetch_all, table, state.backend.list(state.backend_state, table))

  def handle_call({:generic_list_recent, table, limit}, _from, state) do
    result =
      if function_exported?(state.backend, :list_recent, 3),
        do: state.backend.list_recent(state.backend_state, table, limit),
        else: state.backend.list(state.backend_state, table)

    reply_entries(state, :list_recent, table, result)
  end

  defp reply_entries(state, op, table, result) do
    case result do
      {:ok, entries, backend_state} ->
        {:reply, {:ok, entries}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(op, table, :all, reason)
        {:reply, read_failure(op), state}

      other ->
        log_backend_unexpected(op, table, :all, other)
        {:reply, read_failure(op), state}
    end
  end

  @impl true
  def handle_cast({:append_run_event, _run_id, _event}, %{read_only: true} = state),
    do: {:noreply, state}

  def handle_cast({:append_introspection_event, _event}, %{read_only: true} = state),
    do: {:noreply, state}

  def handle_cast({:append_introspection_event, event}, state) do
    case normalize_introspection_event(event) do
      {:ok, event} ->
        key = {event.ts_ms, event.event_id}

        case state.backend.put(state.backend_state, :introspection_log, key, event) do
          {:ok, backend_state} ->
            {:noreply, %{state | backend_state: backend_state}}

          {:error, reason} ->
            log_backend_error(:put, :introspection_log, key, reason)
            {:noreply, state}

          other ->
            log_backend_unexpected(:put, :introspection_log, key, other)
            {:noreply, state}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  # Constant work per event: the event goes into the run's bounded buffer and
  # the record itself is written once, when the run's first event arrives.
  def handle_cast({:append_run_event, run_id, event}, state) do
    buffer = state.run_events

    case :ets.lookup_element(buffer, {run_id, :seq}, 2, 0) do
      0 ->
        case open_run_record(state, run_id) do
          {:open, state} ->
            true = :ets.insert(buffer, {{run_id, :seq}, 1})
            buffer_run_event(buffer, run_id, 1, event)
            {:noreply, state}

          {:closed, state} ->
            {:noreply, state}
        end

      count when count > 0 ->
        seq = count + 1
        true = :ets.insert(buffer, {{run_id, :seq}, seq})
        buffer_run_event(buffer, run_id, seq, event)
        {:noreply, state}

      _frozen ->
        {:noreply, state}
    end
  end

  defp open_run_record(state, run_id) do
    with {:ok, nil, backend_state} <- backend_get(state, state.backend_state, :runs, run_id),
         {:ok, nil, backend_state} <-
           backend_get(state, backend_state, @run_terminals, run_id) do
      record = %{summary: nil, started_at: System.system_time(:millisecond)}

      case state.backend.put(backend_state, :runs, run_id, record) do
        {:ok, backend_state} ->
          ReadCache.put(state.read_cache, :runs, run_id, record)
          {:open, %{state | backend_state: backend_state}}

        {:error, reason} ->
          log_backend_error(:put, :runs, run_id, reason)
          {:closed, %{state | backend_state: backend_state}}

        other ->
          log_backend_unexpected(:put, :runs, run_id, other)
          {:closed, %{state | backend_state: backend_state}}
      end
    else
      {:ok, %{summary: nil}, backend_state} -> {:open, %{state | backend_state: backend_state}}
      {:ok, _finalized, backend_state} -> {:closed, %{state | backend_state: backend_state}}
      {:error, _reason} -> {:closed, state}
    end
  end

  # Keeps the first `@run_event_head` events and the latest ones,
  # `@run_event_limit` in all.
  defp buffer_run_event(buffer, run_id, seq, event) do
    true = :ets.insert(buffer, {{run_id, seq}, event})

    if seq > @run_event_limit do
      :ets.delete(buffer, {run_id, seq - (@run_event_limit - @run_event_head)})
    end

    :ok
  end

  defp drop_run_events(state, run_id) do
    case :ets.take(state.run_events, {run_id, :seq}) do
      [{_key, count}] ->
        reduce_buffer_seqs(abs(count), :ok, fn seq, _acc ->
          :ets.delete(state.run_events, {run_id, seq})
        end)

      [] ->
        :ok
    end

    :ok
  end

  defp freeze_run_events(buffer, run_id) do
    count = :ets.lookup_element(buffer, {run_id, :seq}, 2, 0)
    if count > 0, do: :ets.insert(buffer, {{run_id, :seq}, -count})
  end

  defp expire_run_events(state, cutoff) do
    case :ets.first(state.run_events_expiry) do
      {expires_at, _ref} = key when expires_at < cutoff ->
        [{^key, run_id}] = :ets.take(state.run_events_expiry, key)
        drop_run_events(state, run_id)
        expire_run_events(state, cutoff)

      _ ->
        :ok
    end
  end

  defp backend_get(state, backend_state, table, key) do
    case state.backend.get(backend_state, table, key) do
      {:ok, _value, _backend_state} = ok ->
        ok

      {:error, reason} ->
        log_backend_error(:get, table, key, reason)
        {:error, reason}

      other ->
        log_backend_unexpected(:get, table, key, other)
        {:error, {:unexpected_backend_response, other}}
    end
  end

  defp finalize_run_record(state, run_id, summary) do
    with {:ok, record, backend_state} <- ensure_final_record(state, run_id, summary),
         {:ok, backend_state} <-
           finalize_run_session(state, backend_state, run_id, record, summary) do
      payload = %{
        store: state.name,
        run_id: run_id,
        record: record,
        summary: summary,
        session_key: Map.get(summary, :session_key),
        started_at: record.started_at
      }

      {{:finalized, finalize_run_hooks(state), payload}, %{state | backend_state: backend_state}}
    else
      {:already_projected, backend_state} ->
        {:ok, %{state | backend_state: backend_state}}

      {:error, reason, backend_state} ->
        {{:error, reason}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp ensure_final_record(state, run_id, summary) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(summary, [:deterministic]))

    with {:ok, decision, backend_state} <-
           state.backend.get(state.backend_state, :run_terminals, run_id),
         :ok <- check_terminal_digest(decision, digest, run_id),
         {:ok, existing, backend_state} <- backend_get(state, backend_state, :runs, run_id),
         {:ok, record, backend_state} <-
           final_record_for_commit(state, backend_state, existing, decision, run_id, summary),
         {:ok, backend_state} <-
           ensure_terminal_commit(state, backend_state, decision, run_id, digest, record) do
      if is_nil(existing) and is_map(decision) do
        # Repair from the committed payload without repopulating the live cache.
        {:ok, record, backend_state}
      else
        finalize_live_record(state, backend_state, run_id, record, decision)
      end
    end
  end

  defp check_terminal_digest(nil, _digest, _run_id), do: :ok
  defp check_terminal_digest(%{digest: digest}, digest, _run_id), do: :ok

  defp check_terminal_digest(%{digest: _}, _digest, run_id),
    do: {:error, {:already_finalized, run_id}}

  defp check_terminal_digest(%{finalized_at_ms: _}, _digest, run_id),
    do: {:error, {:already_finalized, run_id}}

  defp check_terminal_digest(_, _, _), do: {:error, :invalid_terminal_decision}

  defp final_record_for_commit(state, backend_state, existing, decision, run_id, summary) do
    case final_record(existing, run_id, summary) do
      {:persist, _record} when is_map(decision) ->
        with {:ok, pending, backend_state} <-
               state.backend.get(backend_state, :run_terminal_pending, run_id) do
          case {decision, pending} do
            {%{digest: digest}, %{digest: digest, record: original}} ->
              {:ok, original, backend_state}

            {%{started_at: _}, nil} ->
              # The decision remains a duplicate barrier after the active row
              # and replay payload are gone. The caller's retry is not a new
              # source for content we have already discarded.
              {:already_projected, backend_state}

            _ ->
              {:error, :invalid_terminal_payload, backend_state}
          end
        end

      {status, record} when status in [:existing, :persist] ->
        {:ok, record, backend_state}

      {:error, reason} ->
        {:error, reason, backend_state}
    end
  end

  defp ensure_terminal_commit(_state, backend_state, %{}, _run_id, _digest, _record),
    do: {:ok, backend_state}

  defp ensure_terminal_commit(state, backend_state, nil, run_id, digest, record) do
    outcome = LemonCore.RunOutcome.infer(record.summary)

    decision = %{
      run_id: run_id,
      attempt_id: terminal_attempt_id(record.summary, run_id),
      outcome: outcome,
      status: terminal_status(outcome),
      digest: digest,
      started_at: record.started_at,
      committed_at_ms: System.system_time(:millisecond)
    }

    pending = %{
      record: put_buffered_events(record, state.run_events, run_id),
      digest: digest,
      indexed: false,
      projections: :pending,
      notification:
        if(is_binary(run_id) and is_map(record.summary[:completed]), do: :pending, else: :done),
      presentation:
        if(match?(%{meta: %{router_owned: true}}, record.summary), do: :pending, else: :done)
    }

    write = fn ->
      run_atomically(state, backend_state, fn ->
        with {:ok, backend_state} <-
               state.backend.put(backend_state, :run_terminal_pending, run_id, pending),
             {:ok, backend_state} <-
               state.backend.put_new(backend_state, :run_terminals, run_id, decision) do
          if function_exported?(state.backend, :with_durability, 2) or
               not function_exported?(state.backend, :sync, 1),
             do: {:ok, backend_state},
             else: state.backend.sync(backend_state)
        else
          {:exists, next_state} -> {:error, {:already_finalized, run_id}, next_state}
          error -> error
        end
      end)
    end

    if function_exported?(state.backend, :with_durability, 2),
      do: state.backend.with_durability(backend_state, write),
      else: write.()
  end

  defp run_atomically(state, backend_state, operation) do
    if function_exported?(state.backend, :atomic, 2),
      do: state.backend.atomic(backend_state, operation),
      else: operation.()
  end

  defp terminal_attempt_id(%{attempt_id: id}, _run_id)
       when is_binary(id) and byte_size(id) <= 256,
       do: id

  defp terminal_attempt_id(_summary, run_id) when is_binary(run_id), do: "#{run_id}:attempt:1"
  defp terminal_attempt_id(_summary, _run_id), do: nil

  defp terminal_status(outcome) when outcome in [:success, :partial], do: :completed
  defp terminal_status(:failure), do: :failed
  defp terminal_status(outcome), do: outcome

  defp final_record(nil, _run_id, summary) do
    {:persist, %{summary: summary, started_at: System.system_time(:millisecond)}}
  end

  defp final_record(%{summary: nil} = record, _run_id, summary) do
    {:persist, %{record | summary: summary}}
  end

  defp final_record(%{summary: summary} = record, _run_id, summary), do: {:existing, record}

  defp final_record(%{summary: _existing_summary}, run_id, _summary) do
    # Do not include the prior summary in the error: summaries may contain
    # prompts, answers, credentials, or other user content.
    {:error, {:already_finalized, run_id}}
  end

  defp final_record(_invalid_record, run_id, _summary),
    do: {:error, {:invalid_run_record, run_id}}

  defp finalize_live_record(state, backend_state, run_id, record, decision) do
    finalized_at =
      (decision || %{})[:committed_at_ms] || record[:finalized_at_ms] ||
        System.system_time(:millisecond)

    expires_at = finalized_at + state.runs_retention_ms
    live_record = Map.merge(record, %{finalized_at_ms: finalized_at, expires_at: expires_at})

    with {:ok, _, backend_state} <-
           persist_final_record(state, backend_state, run_id, live_record) do
      if :ets.member(state.run_events, {run_id, :seq}) and not Map.has_key?(record, :expires_at) do
        freeze_run_events(state.run_events, run_id)
        true = :ets.insert(state.run_events_expiry, {{expires_at, make_ref()}, run_id})
      end

      {:ok, put_buffered_events(live_record, state.run_events, run_id), backend_state}
    end
  end

  defp persist_final_record(state, backend_state, run_id, record) do
    record = Map.drop(record, [:events, :events_dropped])

    case state.backend.put(backend_state, :runs, run_id, record) do
      {:ok, backend_state} ->
        ReadCache.put(state.read_cache, :runs, run_id, record)
        {:ok, record, backend_state}

      {:error, reason} ->
        log_backend_error(:put, :runs, run_id, reason)
        {:error, reason, backend_state}

      other ->
        log_backend_unexpected(:put, :runs, run_id, other)
        {:error, {:unexpected_backend_response, other}, backend_state}
    end
  end

  defp finalize_run_session(state, backend_state, run_id, record, summary) do
    session_key = Map.get(summary, :session_key)

    with {:ok, pending, backend_state} <-
           state.backend.get(backend_state, :run_terminal_pending, run_id) do
      case pending do
        %{indexed: false} ->
          with {:ok, {backend_state, entry}} <-
                 run_atomically(state, backend_state, fn ->
                   with {:ok, backend_state, entry} <-
                          maybe_update_sessions_index(
                            state,
                            backend_state,
                            session_key,
                            run_id,
                            summary,
                            record.started_at
                          ),
                        {:ok, backend_state} <-
                          state.backend.put(backend_state, :run_terminal_pending, run_id, %{
                            pending
                            | indexed: true
                          }) do
                     {:ok, {backend_state, entry}}
                   end
                 end) do
            if entry, do: ReadCache.put(state.read_cache, :sessions_index, session_key, entry)
            {:ok, backend_state}
          end

        _ ->
          {:ok, backend_state}
      end
    end
  end

  defp maybe_update_sessions_index(state, backend_state, session_key, run_id, summary, started_at) do
    if is_binary(session_key) and session_key != "",
      do: update_sessions_index(state, backend_state, session_key, run_id, summary, started_at),
      else: {:ok, backend_state, nil}
  end

  # SQLite commits the durable per-run index acknowledgement and this update
  # together. Keep the bounded recent-run marker for older data and backends
  # without a transaction API.
  defp update_sessions_index(state, backend_state, session_key, run_id, summary, timestamp) do
    case state.backend.get(backend_state, :sessions_index, session_key) do
      {:ok, existing, backend_state} ->
        agent_id = Map.get(summary, :agent_id) || parse_agent_id(session_key)
        origin = get_in(summary, [:meta, :origin]) || Map.get(summary, :origin) || :unknown

        case next_session_entry(existing, session_key, run_id, agent_id, origin, timestamp) do
          {:ok, session_entry} ->
            put_session_index(state, backend_state, session_key, session_entry)

          :already_indexed ->
            {:ok, backend_state, nil}

          {:error, reason} ->
            {:error, reason, backend_state}
        end

      {:error, reason} ->
        log_backend_error(:get, :sessions_index, session_key, reason)
        {:error, reason, backend_state}

      other ->
        log_backend_unexpected(:get, :sessions_index, session_key, other)
        {:error, {:unexpected_backend_response, other}, backend_state}
    end
  end

  defp next_session_entry(nil, session_key, run_id, agent_id, origin, timestamp) do
    {:ok,
     %{
       session_key: session_key,
       incarnation: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
       agent_id: agent_id,
       origin: origin,
       created_at_ms: timestamp,
       updated_at_ms: timestamp,
       run_count: 1,
       __recent_run_ids__: [run_id]
     }}
  end

  defp next_session_entry(entry, _session_key, run_id, _agent_id, _origin, timestamp)
       when is_map(entry) do
    recent_run_ids = recent_run_ids(entry)

    if run_id in recent_run_ids do
      :already_indexed
    else
      recent_run_ids = [run_id | Enum.take(recent_run_ids, @session_index_recent_runs - 1)]

      {:ok,
       entry
       # Entries written before the marker was bounded kept every run id ever
       # indexed; drop that unbounded set on the session's next run.
       |> Map.drop([:__indexed_run_ids__, :__legacy_run_count__])
       |> Map.put(:updated_at_ms, max(entry[:updated_at_ms] || timestamp, timestamp))
       |> Map.put(:run_count, (entry[:run_count] || 0) + 1)
       |> Map.put(:__recent_run_ids__, recent_run_ids)}
    end
  end

  defp next_session_entry(_invalid, session_key, _run_id, _agent_id, _origin, _timestamp),
    do: {:error, {:invalid_session_index, session_key}}

  defp recent_run_ids(entry) do
    case Map.get(entry, :__recent_run_ids__) do
      run_ids when is_list(run_ids) -> run_ids
      _ -> []
    end
  end

  defp put_session_index(state, backend_state, session_key, session_entry) do
    case state.backend.put(backend_state, :sessions_index, session_key, session_entry) do
      {:ok, backend_state} ->
        {:ok, backend_state, session_entry}

      {:error, reason} ->
        log_backend_error(:put, :sessions_index, session_key, reason)
        {:error, reason, backend_state}

      other ->
        log_backend_unexpected(:put, :sessions_index, session_key, other)
        {:error, {:unexpected_backend_response, other}, backend_state}
    end
  end

  defp parse_agent_id(nil), do: "default"

  defp parse_agent_id(session_key) when is_binary(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id | _] -> agent_id
      _ -> "default"
    end
  end

  defp parse_agent_id(_), do: "default"

  defp normalize_introspection_event(event) when is_map(event) do
    event_id = MapHelpers.get_key(event, :event_id)
    ts_ms = MapHelpers.get_key(event, :ts_ms)
    event_type = MapHelpers.get_key(event, :event_type)
    payload = MapHelpers.get_key(event, :payload) || %{}
    provenance = MapHelpers.get_key(event, :provenance) || :direct

    with true <- is_binary(event_id) and event_id != "",
         true <- is_integer(ts_ms) and ts_ms > 0,
         true <- valid_introspection_event_type?(event_type),
         true <- valid_introspection_provenance?(provenance),
         true <- is_map(payload) do
      {:ok,
       %{
         event_id: event_id,
         event_type: event_type,
         ts_ms: ts_ms,
         run_id: normalize_optional_binary(MapHelpers.get_key(event, :run_id)),
         session_key: normalize_optional_binary(MapHelpers.get_key(event, :session_key)),
         agent_id: normalize_optional_binary(MapHelpers.get_key(event, :agent_id)),
         parent_run_id: normalize_optional_binary(MapHelpers.get_key(event, :parent_run_id)),
         engine: normalize_optional_binary(MapHelpers.get_key(event, :engine)),
         provenance: provenance,
         payload: payload
       }}
    else
      _ -> {:error, :invalid_introspection_event}
    end
  end

  defp normalize_introspection_event(_), do: {:error, :invalid_introspection_event}

  defp valid_introspection_event_type?(value) when is_atom(value), do: not is_nil(value)
  defp valid_introspection_event_type?(value) when is_binary(value), do: value != ""
  defp valid_introspection_event_type?(_), do: false

  defp valid_introspection_provenance?(value), do: value in [:direct, :inferred, :unavailable]

  defp normalize_optional_binary(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_binary(_), do: nil

  # Returns true when the opts contain any field-level filter beyond :limit.
  # When no field filters are present, we can skip the Elixir-side filter pass
  # and rely on SQL ORDER BY + LIMIT alone.
  defp introspection_opts_have_field_filters?(opts) do
    Keyword.get(opts, :run_id) != nil or
      Keyword.get(opts, :session_key) != nil or
      Keyword.get(opts, :agent_id) != nil or
      Keyword.get(opts, :event_type) != nil or
      Keyword.get(opts, :since_ms) != nil or
      Keyword.get(opts, :until_ms) != nil
  end

  defp introspection_event_matches?(event, opts) do
    run_id = Keyword.get(opts, :run_id)
    session_key = Keyword.get(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)
    event_type = Keyword.get(opts, :event_type)
    since_ms = Keyword.get(opts, :since_ms)
    until_ms = Keyword.get(opts, :until_ms)

    event_run_id = MapHelpers.get_key(event, :run_id)
    event_session_key = MapHelpers.get_key(event, :session_key)
    event_agent_id = MapHelpers.get_key(event, :agent_id)
    event_event_type = MapHelpers.get_key(event, :event_type)
    event_ts_ms = MapHelpers.get_key(event, :ts_ms)

    optional_binary_match?(run_id, event_run_id) and
      optional_binary_match?(session_key, event_session_key) and
      optional_binary_match?(agent_id, event_agent_id) and
      optional_event_type_match?(event_type, event_event_type) and
      timestamp_range_match?(event_ts_ms, since_ms, until_ms)
  end

  defp optional_binary_match?(nil, _actual), do: true
  defp optional_binary_match?(expected, actual) when is_binary(expected), do: expected == actual
  defp optional_binary_match?(_expected, _actual), do: false

  defp optional_event_type_match?(nil, _actual), do: true

  defp optional_event_type_match?(expected, actual) when is_list(expected) do
    Enum.any?(expected, &event_type_equal?(&1, actual))
  end

  defp optional_event_type_match?(expected, actual), do: event_type_equal?(expected, actual)

  defp event_type_equal?(expected, actual) when is_atom(expected) and is_atom(actual),
    do: expected == actual

  defp event_type_equal?(expected, actual) when is_binary(expected) and is_binary(actual),
    do: expected == actual

  defp event_type_equal?(expected, actual) when is_atom(expected) and is_binary(actual),
    do: Atom.to_string(expected) == actual

  defp event_type_equal?(expected, actual) when is_binary(expected) and is_atom(actual),
    do: expected == Atom.to_string(actual)

  defp event_type_equal?(_expected, _actual), do: false

  defp timestamp_range_match?(ts_ms, since_ms, until_ms) when is_integer(ts_ms) do
    lower_ok = is_nil(since_ms) or (is_integer(since_ms) and ts_ms >= since_ms)
    upper_ok = is_nil(until_ms) or (is_integer(until_ms) and ts_ms <= until_ms)
    lower_ok and upper_ok
  end

  defp timestamp_range_match?(_ts_ms, _since_ms, _until_ms), do: false

  defp introspection_sort_key(event) do
    ts_ms =
      case MapHelpers.get_key(event, :ts_ms) do
        ts when is_integer(ts) -> ts
        _ -> 0
      end

    event_id =
      case MapHelpers.get_key(event, :event_id) do
        id when is_binary(id) -> id
        _ -> ""
      end

    {ts_ms, event_id}
  end

  defp normalize_introspection_limit(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(@max_introspection_query_limit)
  end

  defp normalize_introspection_limit(_), do: @default_introspection_query_limit

  # 48 hours for idempotency entries
  @idempotency_retention_ms 48 * 60 * 60 * 1000

  # A client's ownership process exited (and released its locks): stop writing.
  @impl true
  def handle_info({:DOWN, _ref, :process, _claimer, _reason}, %{defer_to_runtime: true} = state),
    do: {:noreply, %{state | read_only: true, write_refusal: :runtime_owned}}

  def handle_info(:sweep_expired, state) do
    now = System.system_time(:millisecond)

    introspection_sweeps =
      if is_integer(state.introspection_retention_ms) and state.introspection_retention_ms > 0 do
        [{:introspection_log, :introspection_timestamp, now - state.introspection_retention_ms}]
      else
        []
      end

    sweeps =
      Enum.map(@expiring_tables, &{&1, :expires_at, now}) ++
        introspection_sweeps ++
        [
          {:idempotency, :inserted_at_ms, now - @idempotency_retention_ms}
        ]

    backend_state =
      Enum.reduce(sweeps, state.backend_state, fn {table, field, cutoff}, acc ->
        if function_exported?(state.backend, :sweep, 3) do
          case state.backend.sweep(acc, table, {field, cutoff}) do
            {:ok, _count, next} ->
              ReadCache.sweep(state.read_cache, table, field, cutoff)
              if table == :runs, do: expire_run_events(state, cutoff)
              next

            {:error, reason} ->
              log_backend_error(:sweep, table, :all, reason)
              acc
          end
        else
          acc
        end
      end)

    schedule_sweep()
    {:noreply, %{state | backend_state: backend_state}}
  end

  @impl true
  def terminate(_reason, state) do
    # The mirrors and the run-event buffer die with this process; readers must
    # not trust them meanwhile.
    Hooks.publish(state.name, :cached_tables, [])
    Hooks.publish(state.name, :run_events, nil)
    if function_exported?(state.backend, :close, 1), do: state.backend.close(state.backend_state)
    :ok
  end

  defp compare_and_delete_many_fallback(backend, backend_state, entries) do
    with {:ok, backend_state} <- compare_delete_snapshots(backend, backend_state, entries) do
      delete_snapshots(backend, backend_state, entries)
    end
  end

  defp compare_delete_snapshots(backend, backend_state, entries) do
    Enum.reduce_while(entries, {:ok, backend_state}, fn {table, key, expected},
                                                        {:ok, current_state} ->
      case backend.get(current_state, table, key) do
        {:ok, current, next_state} when current === expected ->
          {:cont, {:ok, next_state}}

        {:ok, _current, next_state} ->
          {:halt, {:error, :mismatch, next_state}}

        {:error, reason} ->
          log_backend_error(:compare_and_delete_many, table, key, reason)
          {:halt, {:error, reason, current_state}}

        other ->
          log_backend_unexpected(:compare_and_delete_many, table, key, other)
          {:halt, {:error, :unexpected_backend_response, current_state}}
      end
    end)
  end

  defp delete_snapshots(backend, backend_state, entries) do
    Enum.reduce_while(entries, {:ok, backend_state}, fn {table, key, _}, {:ok, current_state} ->
      case backend.delete(current_state, table, key) do
        {:ok, next_state} ->
          {:cont, {:ok, next_state}}

        {:error, reason} ->
          log_backend_error(:compare_and_delete_many, table, key, reason)
          {:halt, {:error, reason, current_state}}

        other ->
          log_backend_unexpected(:compare_and_delete_many, table, key, other)

          {:halt, {:error, :unexpected_backend_response, current_state}}
      end
    end)
  end

  defp invalidate_snapshot_cache(state, entries) do
    Enum.each(entries, fn {table, key, _expected} ->
      ReadCache.delete(state.read_cache, table, key)
    end)
  end

  # The comparison and write share one backend call, so another OS process on
  # the same storage cannot interleave between them.
  defp backend_compare_and_swap(state, table, key, expected, replacement) do
    case state.backend.compare_and_swap(state.backend_state, table, key, expected, replacement) do
      {:ok, backend_state} ->
        if table in state.cached_tables do
          ReadCache.put(state.read_cache, table, key, replacement)
        end

        {:reply, :ok, %{state | backend_state: backend_state}}

      {:error, :mismatch, backend_state} ->
        if table in state.cached_tables do
          ReadCache.delete(state.read_cache, table, key)
        end

        {:reply, {:error, :mismatch}, %{state | backend_state: backend_state}}

      {:error, reason, backend_state} ->
        log_backend_error(:compare_and_swap, table, key, reason)
        {:reply, {:error, reason}, %{state | backend_state: backend_state}}

      other ->
        log_backend_unexpected(:compare_and_swap, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  defp store_compare_and_swap(state, table, key, expected, replacement) do
    case state.backend.get(state.backend_state, table, key) do
      {:ok, current, backend_state} when current === expected ->
        case state.backend.put(backend_state, table, key, replacement) do
          {:ok, backend_state} ->
            if table in state.cached_tables do
              ReadCache.put(state.read_cache, table, key, replacement)
            end

            {:reply, :ok, %{state | backend_state: backend_state}}

          {:error, reason} ->
            log_backend_error(:compare_and_swap, table, key, reason)
            {:reply, {:error, reason}, %{state | backend_state: backend_state}}

          other ->
            log_backend_unexpected(:compare_and_swap, table, key, other)

            {:reply, {:error, {:unexpected_backend_response, other}},
             %{state | backend_state: backend_state}}
        end

      {:ok, _current, backend_state} ->
        {:reply, {:error, :mismatch}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:compare_and_swap, table, key, reason)
        {:reply, {:error, reason}, state}

      other ->
        log_backend_unexpected(:compare_and_swap, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  defp log_backend_error(op, table, key, reason) do
    Logger.warning(
      "[LemonCore.Store] backend #{op} failed table=#{inspect(table)} " <>
        "key=#{inspect(safe_log_key(table, key))} " <>
        "reason=#{inspect(safe_log_diagnostic(table, reason))}"
    )
  end

  defp log_backend_unexpected(op, table, key, response) do
    Logger.warning(
      "[LemonCore.Store] backend #{op} returned unexpected response table=#{inspect(table)} " <>
        "key=#{inspect(safe_log_key(table, key))} " <>
        "response=#{inspect(safe_log_diagnostic(table, response))}"
    )
  end

  defp log_compare_and_delete_many_unexpected(entries, response) do
    table = sensitive_entry_table(entries) || :multiple

    Logger.warning(
      "[LemonCore.Store] backend compare_and_delete_many returned unexpected response " <>
        "table=#{inspect(table)} entries=:redacted " <>
        "response=#{inspect(safe_log_diagnostic(table, response))}"
    )
  end

  defp bound_compare_and_delete_many_error(_entries, :mismatch), do: :mismatch

  defp bound_compare_and_delete_many_error(_entries, :unexpected_backend_response),
    do: :unexpected_backend_response

  defp bound_compare_and_delete_many_error(entries, reason) do
    case sensitive_entry_table(entries) do
      nil ->
        reason

      table ->
        log_backend_error(:compare_and_delete_many, table, :multiple, reason)
        :store_unavailable
    end
  end

  defp sensitive_entry_table(entries) do
    Enum.find_value(entries, fn
      {table, _key, _expected} -> if sensitive_log_table?(table), do: table
      _malformed -> nil
    end)
  end

  defp safe_log_key(table, key), do: safe_log_diagnostic(table, key)

  defp safe_log_diagnostic(table, term) when is_atom(table) do
    if sensitive_log_table?(table),
      do: sanitize_sensitive_diagnostic(term),
      else: term
  end

  defp safe_log_diagnostic(_table, term), do: term

  defp sensitive_log_table?(table) when is_atom(table),
    do:
      table in [:secrets_v1, :secrets_lock, :node_process_receipts] or
        String.contains?(Atom.to_string(table), "idempotency")

  defp sensitive_log_table?(_table), do: false

  # Sensitive diagnostics are deliberately summarized without traversal. This
  # keeps the logger total and bounded even when a broken backend returns an
  # improper list, an enormous collection, or an extremely deep term.
  defp sanitize_sensitive_diagnostic(term), do: {:redacted, diagnostic_category(term)}

  defp diagnostic_category(term) when is_binary(term), do: {:binary, byte_size(term)}
  defp diagnostic_category(term) when is_bitstring(term), do: {:bitstring, bit_size(term)}
  defp diagnostic_category(term) when is_map(term), do: {:map, map_size(term)}
  defp diagnostic_category(term) when is_tuple(term), do: {:tuple, tuple_size(term)}
  defp diagnostic_category([]), do: :empty_list
  defp diagnostic_category([_head | _tail]), do: :list
  defp diagnostic_category(term) when is_atom(term), do: :atom
  defp diagnostic_category(term) when is_integer(term), do: :integer
  defp diagnostic_category(term) when is_float(term), do: :float
  defp diagnostic_category(term) when is_pid(term), do: :pid
  defp diagnostic_category(term) when is_reference(term), do: :reference
  defp diagnostic_category(term) when is_function(term), do: :function
  defp diagnostic_category(term) when is_port(term), do: :port
  defp diagnostic_category(_term), do: :term
end
