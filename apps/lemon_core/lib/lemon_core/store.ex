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
  `:run_history_provider`), falling back to
  `Application.get_env(:lemon_core, name)` — which for the default name is the
  historical `config :lemon_core, LemonCore.Store` block. Each instance gets its
  own `LemonCore.Store.ReadCache` tables.

  ## Collaborators

  This module is a storage primitive and deliberately knows nothing about chat
  state, policies, memory, chat platforms, or any other domain; typed owners
  such as `LemonCore.ChatStateStore` and `LemonCore.PolicyStore` sit on the
  generic table API, as do owners in other apps (gateway's progress index,
  channels' Telegram indices). Collaborators attach
  to it instead:

    * `:finalize_run_hooks` / `register_finalize_run_hook/2` — notified when a
      run belonging to a session is finalized (see `finalize_run/3`).
    * `:cached_tables` / `register_cached_table/2` — generic tables to mirror
      into the read cache, for owners of hot indexes.
    * `:run_history_provider` — module (or `{module, server}`) that
      `get_run_history/3` forwards to; without one, history reads return `[]`.

  See `LemonCore.Store.Hooks` for hook shapes and failure isolation.

  ## Expiring entries

  Values in `:chat` that carry an integer `:expires_at` (epoch milliseconds)
  are removed by the periodic sweep once that time passes. Owners stamp the
  field; the store only enforces it.

  ## Read cache coherence

  `LemonCore.Store.ReadCache` mirrors hot tables into public ETS so reads skip
  this GenServer. The store process is the cache's **only** writer, and it
  writes only after the backend confirms, so the cache can never advertise a
  value the backend rejected. Consequences worth knowing:

    * Generic writes (`put/4`, `delete/3`, `compare_and_swap/5`, ...) are
      synchronous, so a read taken after one returns cannot observe the
      previous value.
    * `append_run_event/3` stays asynchronous, because runs stream events far
      more often than anything reads them back. Its cache entry lands with the
      backend write, so a read taken before the cast drains can lag by a
      message. `ping/1` is the barrier when that matters.
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
  @expiring_tables [:chat]
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

  # Run Events API

  @doc """
  Append an event to a run's record.

  Asynchronous, because runs stream events far more often than anything reads
  them back. The store updates the cache after the backend write, so a read
  taken before the cast drains can lag by a message; `ping/1` is the barrier
  when a caller needs the write to have landed.
  """
  @spec append_run_event(server(), term(), term()) :: :ok
  def append_run_event(server \\ __MODULE__, run_id, event) do
    GenServer.cast(server, {:append_run_event, run_id, event})
  end

  @doc """
  Record a run's summary and fire the store's finalize-run hooks.

  When the summary carries a non-empty `:session_key`, every hook registered for
  this store (see `register_finalize_run_hook/2`) is invoked with:

      %{
        store: atom(),        # the store's name
        run_id: term(),
        record: map(),        # %{events: [...], summary: ..., started_at: ...}
        summary: map(),
        session_key: String.t(),
        started_at: integer()
      }

  Hooks run in the store process, in registration order, and failures are
  isolated. Runs without a session key do not fire hooks.

  Hook delivery is **at least once**. Hooks run only after the run record and
  session index are written, but retrying a successful finalization invokes
  them again. Hook implementations must therefore be idempotent by `run_id`.
  """
  @spec finalize_run(server(), term(), map()) :: :ok | {:error, term()}
  def finalize_run(server \\ __MODULE__, run_id, summary)

  def finalize_run(server, run_id, summary) when is_map(summary) do
    safe_store_call(server, {:finalize_run, run_id, summary}, {:error, :store_unavailable},
      op: :finalize_run,
      table: :runs,
      key: run_id
    )
  end

  def finalize_run(_server, _run_id, _summary), do: {:error, :invalid_summary}

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

  Returns `nil` if the key doesn't exist.
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
  """
  @spec list(server(), table :: atom()) :: [{term(), term()}]
  def list(server \\ __MODULE__, table) do
    if cached_table?(server, table) do
      ReadCache.list(server, table)
    else
      safe_store_call(server, {:generic_list, table}, [], op: :list, table: table, key: :all)
    end
  end

  @doc """
  List all key-value pairs without collapsing backend or process failure.

  Unlike `list/2`, this always consults the owning Store process and returns an
  error when the backend cannot confirm the complete table contents.
  Correctness-sensitive cleanup and migration paths should use this function
  before advancing durable sweep watermarks.
  """
  @spec fetch_all(server(), table :: atom()) ::
          {:ok, [{term(), term()}]} | {:error, :store_unavailable}
  def fetch_all(server \\ __MODULE__, table) do
    safe_store_call(
      server,
      {:generic_fetch_all, table},
      {:error, :store_unavailable},
      op: :fetch_all,
      table: table,
      key: :all
    )
  end

  # Whether this store mirrors `table` into the read cache. Read from the
  # store's published configuration so caller processes stay off the GenServer.
  defp cached_table?(server, table) when is_atom(server) and not is_nil(server) do
    table in Hooks.published(server, :cached_tables, [])
  end

  defp cached_table?(_server, _table), do: false

  @doc """
  Mirror `table` into this store's read cache from now on.

  Registration is remembered in `:persistent_term`, so it survives a store
  restart and may be made before the store boots. Collaborators that own a
  generic table call this at startup rather than the store hard-coding it:

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

  # Run History API

  @doc """
  Get run history for a session key, ordered by most recent first.

  ## Options

    * `:limit` - Maximum number of runs to return (default: 10)

  Returns a list of `{run_id, %{events: [...], summary: %{...}, session_key: key, started_at: ts}}`.

  Session keys are binaries, and the guard says so: it is what stops
  `get_run_history(:my_store, opts)` — which reads as "from this instance" but
  means "for this session on the default store" — from silently returning the
  wrong answer. Address an instance with `get_run_history/3`.
  """
  @spec get_run_history(binary(), keyword()) :: [{term(), map()}]
  def get_run_history(session_key, opts \\ []) when is_binary(session_key) and is_list(opts),
    do: get_run_history(__MODULE__, session_key, opts)

  @doc """
  Get run history for a session key from a specific store instance.
  """
  @spec get_run_history(server(), term(), keyword()) :: [{term(), map()}]
  def get_run_history(server, session_key, opts) when is_list(opts) do
    safe_store_call(server, {:get_run_history, session_key, opts}, [],
      op: :get_run_history,
      table: :run_history,
      key: session_key
    )
  end

  @doc """
  Get a specific run by ID.
  """
  @spec get_run(server(), term()) :: map() | nil
  def get_run(server \\ __MODULE__, run_id) do
    # Fast path: direct ETS cache lookup
    case ReadCache.get(server, :runs, run_id) do
      nil ->
        safe_store_call(server, {:get_run, run_id}, nil, op: :get_run, table: :runs, key: run_id)

      value ->
        value
    end
  end

  @doc """
  Fetch a specific run by ID without collapsing storage failures into absence.

  Use this at correctness boundaries where a missing run permits a mutation:
  `{:ok, nil}` proves absence, while `{:error, :store_unavailable}` preserves
  an unknown outcome when the backend cannot answer.
  """
  @spec fetch_run(server(), term()) :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch_run(server \\ __MODULE__, run_id) do
    case ReadCache.fetch(server, :runs, run_id) do
      {:ok, value} ->
        {:ok, value}

      _miss_or_uncached ->
        safe_store_call(
          server,
          {:fetch_run, run_id},
          {:error, :store_unavailable},
          op: :fetch_run,
          table: :runs,
          key: run_id
        )
    end
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
  @spec list_introspection_events(keyword()) :: [map()]
  def list_introspection_events(opts \\ []) when is_list(opts),
    do: list_introspection_events(__MODULE__, opts)

  @doc """
  List introspection events from a specific store instance.
  """
  @spec list_introspection_events(server(), keyword()) :: [map()]
  def list_introspection_events(server, opts) when is_list(opts) do
    safe_store_call(server, {:list_introspection_events, opts}, [],
      op: :list_introspection_events,
      table: :introspection_log,
      key: :all
    )
  end

  defp safe_store_call(server, request, fallback, context) do
    GenServer.call(server, request, @store_call_timeout_ms)
  catch
    :exit, reason ->
      Logger.warning(
        "Store client call failed store=#{inspect(server)} op=#{inspect(context[:op])} " <>
          "table=#{inspect(context[:table])} " <>
          "key=#{inspect(safe_log_key(context[:table], context[:key]))} " <>
          "reason=#{inspect(store_call_exit_reason(reason))}"
      )

      fallback
  end

  defp store_call_exit_reason({:timeout, {GenServer, :call, _}}), do: :timeout
  defp store_call_exit_reason({:noproc, {GenServer, :call, _}}), do: :noproc
  defp store_call_exit_reason({:shutdown, {GenServer, :call, _}}), do: :shutdown
  defp store_call_exit_reason(_), do: :exit

  # GenServer Implementation

  # Server-side only: called from `init/1` and the register-cached-table call,
  # both of which run in the store process. It lives below this line because
  # everything that touches the cache does.
  defp warm_cached_tables(backend, backend_state, read_cache, tables) do
    Enum.reduce(tables, backend_state, fn table, acc_state ->
      case backend.list(acc_state, table) do
        {:ok, entries, next_state} ->
          Enum.each(entries, fn {key, value} ->
            ReadCache.put(read_cache, table, key, value)
          end)

          next_state

        {:error, reason} ->
          Logger.warning(
            "Store cache warm failed table=#{inspect(table)} reason=#{inspect(reason)}"
          )

          acc_state

        other ->
          Logger.warning(
            "Store cache warm failed table=#{inspect(table)} reason=#{inspect(other)}"
          )

          acc_state
      end
    end)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config = resolve_config(name, opts)

    backend = Keyword.get(config, :backend, @default_backend)
    backend_opts = Keyword.get(config, :backend_opts, [])
    run_history_provider = Keyword.get(config, :run_history_provider)
    finalize_run_hooks = List.wrap(Keyword.get(config, :finalize_run_hooks, []))

    cached_tables =
      Enum.uniq(
        List.wrap(Keyword.get(config, :cached_tables, @default_cached_tables)) ++
          Hooks.registered(name, :cached_tables)
      )

    case backend.init(backend_opts) do
      {:ok, backend_state} ->
        # Initialize this instance's read-through cache for high-traffic domains
        read_cache = ReadCache.init(name, cached_tables)

        backend_state =
          warm_cached_tables(backend, backend_state, read_cache, cached_tables)

        # Published only once the tables hold the backend's contents: callers
        # read this to decide whether to trust the cache, and between the
        # publish and the warm a mirrored table would look authoritative while
        # still being empty.
        Hooks.publish(name, :cached_tables, cached_tables)

        # Schedule periodic sweep for expired entries
        schedule_sweep()

        {:ok,
         %{
           name: name,
           read_cache: read_cache,
           cached_tables: cached_tables,
           finalize_run_hooks: finalize_run_hooks,
           run_history_provider: run_history_provider,
           backend: backend,
           backend_state: backend_state,
           introspection_retention_ms: @default_introspection_retention_ms
         }}

      {:error, reason} ->
        {:stop, {:backend_init_failed, reason}}
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
      :run_history_provider
    ])
    |> then(&Keyword.merge(env_config, &1))
  end

  # Deduplicated across both sources: a collaborator that is listed in config
  # *and* registers itself at boot is one hook, not two. Without this, wiring it
  # both ways silently ingests every finalized run twice.
  defp finalize_run_hooks(state) do
    Enum.uniq(state.finalize_run_hooks ++ Hooks.registered(state.name, :finalize_run_hooks))
  end

  # The read side of run history belongs to whoever owns run history; the store
  # only forwards to the configured provider (`{module, server}` or `module`).
  defp run_history_get(nil, _session_key, _opts), do: []

  defp run_history_get(provider, session_key, opts) do
    {module, server} =
      case provider do
        {module, server} -> {module, server}
        module when is_atom(module) -> {module, module}
      end

    Hooks.safely(fn -> module.get(server, session_key, opts) end, [],
      op: :get_run_history,
      provider: provider
    )
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
      cached_tables = state.cached_tables ++ [table]

      backend_state =
        warm_cached_tables(state.backend, state.backend_state, read_cache, [table])

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
    case state.backend.get(state.backend_state, :runs, run_id) do
      {:ok, value, backend_state} ->
        if not is_nil(value) do
          ReadCache.put(state.read_cache, :runs, run_id, value)
        end

        {:reply, {:ok, value}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:fetch, :runs, run_id, reason)
        {:reply, {:error, :store_unavailable}, state}

      other ->
        log_backend_unexpected(:fetch, :runs, run_id, other)
        {:reply, {:error, :store_unavailable}, state}
    end
  end

  def handle_call({:finalize_run, run_id, summary}, _from, state) do
    {reply, state} = finalize_run_record(state, run_id, summary)
    {:reply, reply, state}
  end

  def handle_call({:get_run_history, session_key, opts}, _from, state) do
    # Forwarded to the configured provider, which owns run history and keeps
    # potentially large history I/O off this process.
    result = run_history_get(state.run_history_provider, session_key, opts)
    {:reply, result, state}
  end

  def handle_call({:list_introspection_events, opts}, _from, state) do
    limit =
      normalize_introspection_limit(Keyword.get(opts, :limit, @default_introspection_query_limit))

    has_field_filters = introspection_opts_have_field_filters?(opts)

    backend_supports_list_recent =
      function_exported?(state.backend, :list_recent, 3)

    # Optimization: when no field-level filters are active AND the backend
    # supports list_recent/3, push ORDER BY + LIMIT into SQL so we don't
    # load all rows into memory.
    result =
      if backend_supports_list_recent and not has_field_filters do
        state.backend.list_recent(state.backend_state, :introspection_log, limit)
      else
        state.backend.list(state.backend_state, :introspection_log)
      end

    case result do
      {:ok, entries, backend_state} ->
        events =
          if backend_supports_list_recent and not has_field_filters do
            # Already limited and ordered by recency from SQL; just extract
            # values and sort by the canonical sort key for stable ordering.
            entries
            |> Enum.map(fn {_key, event} -> event end)
            |> Enum.sort_by(&introspection_sort_key/1, :desc)
          else
            entries
            |> Enum.map(fn {_key, event} -> event end)
            |> Enum.filter(&introspection_event_matches?(&1, opts))
            |> Enum.sort_by(&introspection_sort_key/1, :desc)
            |> Enum.take(limit)
          end

        {:reply, events, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:list, :introspection_log, :all, reason)
        {:reply, [], state}

      other ->
        log_backend_unexpected(:list, :introspection_log, :all, other)
        {:reply, [], state}
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
        if table in state.cached_tables do
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

  def handle_call(:sync, _from, state) do
    if function_exported?(state.backend, :sync, 1) do
      case state.backend.sync(state.backend_state) do
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

  def handle_call({:generic_list, table}, _from, state) do
    case state.backend.list(state.backend_state, table) do
      {:ok, entries, backend_state} ->
        {:reply, entries, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:list, table, :all, reason)
        {:reply, [], state}

      other ->
        log_backend_unexpected(:list, table, :all, other)
        {:reply, [], state}
    end
  end

  def handle_call({:generic_fetch_all, table}, _from, state) do
    case state.backend.list(state.backend_state, table) do
      {:ok, entries, backend_state} ->
        {:reply, {:ok, entries}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:fetch_all, table, :all, reason)
        {:reply, {:error, :store_unavailable}, state}

      other ->
        log_backend_unexpected(:fetch_all, table, :all, other)
        {:reply, {:error, :store_unavailable}, state}
    end
  end

  @impl true
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

  def handle_cast({:append_run_event, run_id, event}, state) do
    case state.backend.get(state.backend_state, :runs, run_id) do
      {:ok, existing, backend_state} ->
        record =
          existing || %{events: [], summary: nil, started_at: System.system_time(:millisecond)}

        record = %{record | events: [event | record.events]}

        case state.backend.put(backend_state, :runs, run_id, record) do
          {:ok, backend_state} ->
            ReadCache.put(state.read_cache, :runs, run_id, record)
            {:noreply, %{state | backend_state: backend_state}}

          {:error, reason} ->
            log_backend_error(:put, :runs, run_id, reason)
            {:noreply, %{state | backend_state: backend_state}}

          other ->
            log_backend_unexpected(:put, :runs, run_id, other)
            {:noreply, %{state | backend_state: backend_state}}
        end

      {:error, reason} ->
        log_backend_error(:get, :runs, run_id, reason)
        {:noreply, state}

      other ->
        log_backend_unexpected(:get, :runs, run_id, other)
        {:noreply, state}
    end
  end

  defp finalize_run_record(state, run_id, summary) do
    with {:ok, record, backend_state} <- ensure_final_record(state, run_id, summary),
         {:ok, backend_state} <-
           finalize_run_session(state, backend_state, run_id, record, summary) do
      {:ok, %{state | backend_state: backend_state}}
    else
      {:error, reason, backend_state} ->
        {{:error, reason}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp ensure_final_record(state, run_id, summary) do
    case state.backend.get(state.backend_state, :runs, run_id) do
      {:ok, existing, backend_state} ->
        case final_record(existing, run_id, summary) do
          {:persist, record} -> persist_final_record(state, backend_state, run_id, record)
          {:existing, record} -> {:ok, record, backend_state}
          {:error, reason} -> {:error, reason, backend_state}
        end

      {:error, reason} ->
        log_backend_error(:get, :runs, run_id, reason)
        {:error, reason}

      other ->
        log_backend_unexpected(:get, :runs, run_id, other)
        {:error, {:unexpected_backend_response, other}}
    end
  end

  defp final_record(nil, _run_id, summary) do
    {:persist, %{events: [], summary: summary, started_at: System.system_time(:millisecond)}}
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

  defp persist_final_record(state, backend_state, run_id, record) do
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

    if is_binary(session_key) and session_key != "" do
      with {:ok, backend_state} <-
             update_sessions_index(
               state,
               backend_state,
               session_key,
               run_id,
               summary,
               record.started_at
             ) do
        Hooks.invoke(
          finalize_run_hooks(state),
          %{
            store: state.name,
            run_id: run_id,
            record: record,
            summary: summary,
            session_key: session_key,
            started_at: record.started_at
          },
          op: :finalize_run,
          store: state.name,
          run_id: run_id
        )

        {:ok, backend_state}
      end
    else
      {:ok, backend_state}
    end
  end

  # Update sessions_index when a run is finalized. `:__recent_run_ids__` holds
  # the ids of the last `@session_index_recent_runs` runs counted into the entry,
  # newest first. It is the idempotency marker that lets a retried finalization
  # repair a partial failure without counting its run twice, and it is bounded
  # so a long-lived session's entry stays a fixed size: a retry that arrives
  # after that many newer runs of the same session were indexed counts again.
  # Typed public listings strip the marker before returning session entries.
  defp update_sessions_index(state, backend_state, session_key, run_id, summary, timestamp) do
    case state.backend.get(backend_state, :sessions_index, session_key) do
      {:ok, existing, backend_state} ->
        agent_id = Map.get(summary, :agent_id) || parse_agent_id(session_key)
        origin = get_in(summary, [:meta, :origin]) || Map.get(summary, :origin) || :unknown

        case next_session_entry(existing, session_key, run_id, agent_id, origin, timestamp) do
          {:ok, session_entry} ->
            put_session_index(state, backend_state, session_key, session_entry)

          :already_indexed ->
            {:ok, backend_state}

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
        ReadCache.put(state.read_cache, :sessions_index, session_key, session_entry)
        {:ok, backend_state}

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
  # 48 hours for cron run entries
  @cron_runs_retention_ms 48 * 60 * 60 * 1000

  @impl true
  def handle_info(:sweep_expired, state) do
    cache = state.read_cache

    backend_state =
      Enum.reduce(@expiring_tables, state.backend_state, fn table, acc_state ->
        sweep_expired_entries(state.backend, acc_state, table, cache)
      end)

    backend_state =
      sweep_expired_introspection_events(
        state.backend,
        backend_state,
        state.introspection_retention_ms,
        cache
      )

    backend_state = sweep_expired_idempotency(state.backend, backend_state, cache)
    backend_state = sweep_expired_cron_runs(state.backend, backend_state, cache)

    schedule_sweep()
    {:noreply, %{state | backend_state: backend_state}}
  end

  # Every sweeper evicts what it deletes. `ReadCache.delete/3` is a no-op for a
  # domain this store does not mirror, so the call is unconditional: a table
  # that later becomes cached (`register_cached_table/2`) is covered without
  # anyone remembering to add it here.
  defp sweep_expired_entries(backend, backend_state, table, cache) do
    case backend.list(backend_state, table) do
      {:ok, entries, backend_state} ->
        now = System.system_time(:millisecond)

        Enum.reduce(entries, backend_state, fn {key, value}, acc_state ->
          case value do
            %{expires_at: expires_at} when is_integer(expires_at) and now > expires_at ->
              case backend.delete(acc_state, table, key) do
                {:ok, new_state} ->
                  ReadCache.delete(cache, table, key)
                  new_state

                {:error, reason} ->
                  log_backend_error(:delete, table, key, reason)
                  acc_state

                other ->
                  log_backend_unexpected(:delete, table, key, other)
                  acc_state
              end

            _ ->
              acc_state
          end
        end)

      {:error, reason} ->
        log_backend_error(:list, table, :all, reason)
        backend_state

      other ->
        log_backend_unexpected(:list, table, :all, other)
        backend_state
    end
  end

  defp sweep_expired_introspection_events(_backend, backend_state, retention_ms, _cache)
       when not is_integer(retention_ms) or retention_ms <= 0 do
    backend_state
  end

  defp sweep_expired_introspection_events(backend, backend_state, retention_ms, cache) do
    case backend.list(backend_state, :introspection_log) do
      {:ok, all_events, backend_state} ->
        cutoff_ms = System.system_time(:millisecond) - retention_ms

        Enum.reduce(all_events, backend_state, fn {key, event}, acc_state ->
          event_ts_ms = introspection_event_timestamp(key, event)

          if is_integer(event_ts_ms) and event_ts_ms < cutoff_ms do
            case backend.delete(acc_state, :introspection_log, key) do
              {:ok, next_state} ->
                ReadCache.delete(cache, :introspection_log, key)
                next_state

              {:error, reason} ->
                log_backend_error(:delete, :introspection_log, key, reason)
                acc_state

              other ->
                log_backend_unexpected(:delete, :introspection_log, key, other)
                acc_state
            end
          else
            acc_state
          end
        end)

      {:error, reason} ->
        log_backend_error(:list, :introspection_log, :all, reason)
        backend_state

      other ->
        log_backend_unexpected(:list, :introspection_log, :all, other)
        backend_state
    end
  end

  defp introspection_event_timestamp({ts_ms, _event_id}, _event) when is_integer(ts_ms), do: ts_ms

  defp introspection_event_timestamp(_key, event) when is_map(event) do
    case MapHelpers.get_key(event, :ts_ms) do
      ts when is_integer(ts) -> ts
      _ -> nil
    end
  end

  defp introspection_event_timestamp(_key, _event), do: nil

  defp sweep_expired_idempotency(backend, backend_state, cache) do
    case backend.list(backend_state, :idempotency) do
      {:ok, entries, backend_state} ->
        cutoff_ms = System.system_time(:millisecond) - @idempotency_retention_ms

        Enum.reduce(entries, backend_state, fn {key, value}, acc_state ->
          inserted_at =
            case value do
              %{"inserted_at_ms" => ts} when is_integer(ts) -> ts
              _ -> nil
            end

          if is_integer(inserted_at) and inserted_at < cutoff_ms do
            case backend.delete(acc_state, :idempotency, key) do
              {:ok, next_state} ->
                ReadCache.delete(cache, :idempotency, key)
                next_state

              _ ->
                acc_state
            end
          else
            acc_state
          end
        end)

      _ ->
        backend_state
    end
  end

  defp sweep_expired_cron_runs(backend, backend_state, cache) do
    case backend.list(backend_state, :cron_runs) do
      {:ok, entries, backend_state} ->
        cutoff_ms = System.system_time(:millisecond) - @cron_runs_retention_ms

        Enum.reduce(entries, backend_state, fn {key, value}, acc_state ->
          # Use started_at_ms as the age reference for cron runs
          started_at =
            case value do
              %{started_at_ms: ts} when is_integer(ts) -> ts
              %{"started_at_ms" => ts} when is_integer(ts) -> ts
              _ -> nil
            end

          if is_integer(started_at) and started_at < cutoff_ms do
            case backend.delete(acc_state, :cron_runs, key) do
              {:ok, next_state} ->
                ReadCache.delete(cache, :cron_runs, key)
                next_state

              _ ->
                acc_state
            end
          else
            acc_state
          end
        end)

      _ ->
        backend_state
    end
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
      if table in state.cached_tables do
        ReadCache.delete(state.read_cache, table, key)
      end
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
