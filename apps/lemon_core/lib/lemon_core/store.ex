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
  `:backend_opts`, `:cached_tables`, `:table_modules`, `:sweep_interval_ms`),
  falling back to `Application.get_env(:lemon_core, name)` — which for the
  default name is the historical `config :lemon_core, LemonCore.Store` block.
  Each instance gets its own `LemonCore.Store.ReadCache` tables and its own
  table registrations.

  ## Tables

  Any atom names a table, created on demand. The modules that own tables
  declare them with `LemonCore.Store.Table` and register them, either one at
  a time with `register_table/2` or a module at a time with
  `LemonCore.Store.Table.register/2`. Registration is how a table gets a
  read-cache mirror, an expiry policy and a persistence hint; it is also the
  record of who owns what. Every instance registers `lemon_core`'s own table
  modules at boot (`:table_modules`); other applications register theirs
  when they start.

  The store knows nothing about what a table holds. Run records, chat state,
  progress mappings, policies and introspection events live in
  `LemonCore.RunStore`, `LemonCore.ChatStateStore`, `LemonCore.ProgressStore`,
  `LemonCore.PolicyStore` and `LemonCore.IntrospectionStore`, which own their
  meaning, validation, defaults and retention over the operations here.

  ## Reads

  `get/3` answers `nil` both for a missing key and for a store it could not
  reach; `fetch/3` tells the two apart (`:error` versus `{:error, reason}`)
  for callers that must. Neither can distinguish a stored `nil` from an
  absent key.

  ## Writes, synchronous and asynchronous

  `put/4`, `put_new/4`, `compare_and_swap/5`, `update/5`, `delete/3` and
  `take/3` are calls: when they return, the backend has confirmed the write
  and the read cache agrees. `update/5` and `compare_and_swap/5` run their
  read and write inside the store process, so concurrent writers to one key
  serialize there.

  `put_async/4` and `update_async/5` are casts, for writers that produce far
  more than anything reads back. Their cache entry lands with the backend
  write, so a read taken before the cast drains can lag by a message;
  `ping/1` is the barrier when that matters, and a failed asynchronous write
  is logged rather than returned.

  ## Read cache coherence

  `LemonCore.Store.ReadCache` mirrors registered tables into public ETS so
  reads skip this GenServer. The store process is the cache's **only**
  writer, and it writes only after the backend confirms, so the cache can
  never advertise a value the backend rejected. Sweeps evict what they
  delete for the same reason.
  """

  use GenServer

  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.Hooks
  alias LemonCore.Store.ReadCache
  alias LemonCore.Store.Table
  require Logger

  @default_backend EtsBackend
  # Sweep interval: 5 minutes in milliseconds
  @default_sweep_interval_ms 5 * 60 * 1000
  @store_call_timeout_ms 5_000
  # The tables lemon_core itself owns. Every instance registers them, so a
  # second store behaves like the first for the domains core ships with.
  @default_table_modules [
    LemonCore.ChatStateStore,
    LemonCore.ProgressStore,
    LemonCore.RunStore,
    LemonCore.PolicyStore,
    LemonCore.IntrospectionStore,
    LemonCore.IdempotencyStore
  ]

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

  @doc "Performs a non-mutating store/backend liveness check."
  @spec ping(server()) :: :ok | {:error, term()}
  def ping(server \\ __MODULE__) do
    safe_store_call(server, :ping, {:error, :store_unavailable},
      op: :ping,
      table: :store,
      key: :ping
    )
  end

  # Generic Table API

  @doc """
  Put a value into a named table.
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
  Put a value into a named table without waiting for the write.

  A failed write is logged; see the module documentation for when a read can
  observe the previous value.
  """
  @spec put_async(server(), atom(), term(), term()) :: :ok
  def put_async(server \\ __MODULE__, table, key, value) do
    GenServer.cast(server, {:generic_put_async, table, key, value})
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

  The read and write are serialized inside the Store process. `nil` matches a
  missing key (and, like `get/3`, cannot distinguish a stored `nil`).
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
  Atomically replaces the value at `key` with `fun.(current)`.

  `fun` receives the current value, or `default` when the key is absent, and
  runs inside the store process, so it must be quick and must not call back
  into the store. Returns the value written. A `fun` that raises is a bug in
  the owner: it is logged with its stacktrace and answered as
  `{:error, {:update_failed, exception}}`, and nothing is written.
  """
  @spec update(server(), atom(), term(), term(), (term() -> term())) ::
          {:ok, term()} | {:error, term()}
  def update(server \\ __MODULE__, table, key, default, fun) when is_function(fun, 1) do
    safe_store_call(
      server,
      {:generic_update, table, key, default, fun},
      {:error, :store_unavailable},
      op: :update,
      table: table,
      key: key
    )
  end

  @doc """
  `update/5` without waiting for the write. A failing update is logged.
  """
  @spec update_async(server(), atom(), term(), term(), (term() -> term())) :: :ok
  def update_async(server \\ __MODULE__, table, key, default, fun) when is_function(fun, 1) do
    GenServer.cast(server, {:generic_update_async, table, key, default, fun})
  end

  @doc """
  Get a value from a named table.

  Returns `nil` if the key doesn't exist, and also when the store could not
  be reached; `fetch/3` distinguishes the two.
  """
  @spec get(server(), table :: atom(), key :: term()) :: term() | nil
  def get(server \\ __MODULE__, table, key) do
    case fetch(server, table, key) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  @doc """
  Fetch a value from a named table.

  Answers `{:ok, value}`, `:error` for an absent key, and `{:error, reason}`
  when the backend failed or the store is unavailable.
  """
  @spec fetch(server(), atom(), term()) :: {:ok, term()} | :error | {:error, term()}
  def fetch(server \\ __MODULE__, table, key) do
    with true <- cached_table?(server, table),
         {:ok, value} <- ReadCache.fetch(server, table, key) do
      {:ok, value}
    else
      # Either the table is not mirrored or we missed. The store answers, and
      # populates its own cache on the way out when the table is mirrored — the
      # cache has a single writer, so a caller never publishes a value the
      # backend has not confirmed.
      _uncached_or_miss ->
        safe_store_call(server, {:generic_fetch, table, key}, {:error, :store_unavailable},
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
  At most `limit` entries of a named table, most recently written first when
  the backend keeps write times.

  Answers `{:error, :unsupported}` from a backend without that notion (the
  ETS backend), so the caller can fall back to `list/2`.
  """
  @spec list_recent(server(), atom(), pos_integer()) ::
          {:ok, [{term(), term()}]} | {:error, :unsupported | term()}
  def list_recent(server \\ __MODULE__, table, limit) when is_integer(limit) and limit > 0 do
    safe_store_call(server, {:generic_list_recent, table, limit}, {:error, :store_unavailable},
      op: :list_recent,
      table: table,
      key: :all
    )
  end

  @doc """
  Run the retention sweep now, instead of waiting for the periodic one.
  """
  @spec sweep(server()) :: :ok | {:error, term()}
  def sweep(server \\ __MODULE__) do
    safe_store_call(server, :sweep, {:error, :store_unavailable},
      op: :sweep,
      table: :store,
      key: :all
    )
  end

  # Whether this store mirrors `table` into the read cache. Read from the
  # store's published configuration so caller processes stay off the GenServer.
  defp cached_table?(server, table) when is_atom(server) and not is_nil(server) do
    table in Hooks.published(server, :cached_tables, [])
  end

  defp cached_table?(_server, _table), do: false

  # Table registration

  @doc """
  Register a declared table with this store.

  Registration is remembered per store name, so it survives a store restart
  and may be made before the store boots; a running store applies it at
  once (cache mirror, retention, backend hint). A table another module
  already owns is refused as `{:error, {:already_owned, name, owner}}`.
  """
  @spec register_table(atom(), Table.t()) :: :ok | {:error, term()}
  def register_table(server \\ __MODULE__, %Table{} = table)
      when is_atom(server) and not is_nil(server) do
    with :ok <- Table.put_registration(server, table) do
      case GenServer.whereis(server) do
        # A running store applies the registration now. The store registering
        # its own default modules from `init/1` reads the registry right after,
        # so it must not call itself.
        pid when is_pid(pid) and pid != self() ->
          safe_store_call(server, {:register_table, table}, {:error, :store_unavailable},
            op: :register_table,
            table: table.name,
            key: :all
          )

        _not_running_or_self ->
          :ok
      end
    end
  end

  @doc "The tables registered with this store, as their declarations."
  @spec registered_tables(atom()) :: [Table.t()]
  def registered_tables(server \\ __MODULE__) when is_atom(server), do: Table.registered(server)

  @doc """
  Mirror `table` into this store's read cache from now on.

  The lighter form of `register_table/2` for a table that needs nothing but
  the mirror. Registration is remembered in `:persistent_term`, so it
  survives a store restart and may be made before the store boots.
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

  defp safe_store_call(server, request, fallback, context) do
    GenServer.call(server, request, @store_call_timeout_ms)
  catch
    :exit, reason ->
      Logger.warning(
        "Store client call failed store=#{inspect(server)} op=#{inspect(context[:op])} " <>
          "table=#{inspect(context[:table])} key=#{inspect(context[:key])} " <>
          "reason=#{inspect(store_call_exit_reason(reason))}"
      )

      fallback
  end

  defp store_call_exit_reason({:timeout, {GenServer, :call, _}}), do: :timeout
  defp store_call_exit_reason({:noproc, {GenServer, :call, _}}), do: :noproc
  defp store_call_exit_reason({:shutdown, {GenServer, :call, _}}), do: :shutdown
  defp store_call_exit_reason(_), do: :exit

  # GenServer Implementation

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    config = resolve_config(name, opts)

    backend = Keyword.get(config, :backend, @default_backend)
    backend_opts = Keyword.get(config, :backend_opts, [])
    sweep_interval_ms = Keyword.get(config, :sweep_interval_ms, @default_sweep_interval_ms)

    config
    |> Keyword.get(:table_modules, @default_table_modules)
    |> Enum.each(&Table.register(name, &1))

    tables = name |> Table.registered() |> Map.new(&{&1.name, &1})

    cached_tables =
      Enum.uniq(
        List.wrap(Keyword.get(config, :cached_tables, [])) ++
          Hooks.registered(name, :cached_tables) ++
          for({table_name, %Table{cached: true}} <- tables, do: table_name)
      )

    case backend.init(backend_opts) do
      {:ok, backend_state} ->
        backend_state = register_backend_tables(backend, backend_state, Map.values(tables))

        # Initialize this instance's read-through cache for the mirrored tables
        read_cache = ReadCache.init(name, cached_tables)

        backend_state =
          warm_cached_tables(backend, backend_state, read_cache, cached_tables)

        # Published only once the tables hold the backend's contents: callers
        # read this to decide whether to trust the cache, and between the
        # publish and the warm a mirrored table would look authoritative while
        # still being empty.
        Hooks.publish(name, :cached_tables, cached_tables)

        schedule_sweep(sweep_interval_ms)

        {:ok,
         %{
           name: name,
           read_cache: read_cache,
           cached_tables: cached_tables,
           tables: tables,
           backend: backend,
           backend_state: backend_state,
           sweep_interval_ms: sweep_interval_ms
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
    |> Keyword.take([:backend, :backend_opts, :cached_tables, :table_modules, :sweep_interval_ms])
    |> then(&Keyword.merge(env_config, &1))
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

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end

  # Backends that understand a declaration (an ephemeral hint, say) are told
  # about each registered table; the callback is optional.
  defp register_backend_tables(backend, backend_state, tables) do
    if function_exported?(backend, :register_table, 2) do
      Enum.reduce(tables, backend_state, fn table, acc ->
        case backend.register_table(acc, table) do
          {:ok, next_state} ->
            next_state

          other ->
            log_backend_unexpected(:register_table, table.name, :all, other)
            acc
        end
      end)
    else
      backend_state
    end
  end

  # Server-side only: called from `init/1` and the register calls, all of
  # which run in the store process. It lives below this line because
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
    {:reply, :ok, add_cached_table(state, table)}
  end

  def handle_call({:register_table, %Table{} = table}, _from, state) do
    backend_state = register_backend_tables(state.backend, state.backend_state, [table])

    state = %{
      state
      | backend_state: backend_state,
        tables: Map.put(state.tables, table.name, table)
    }

    state = if table.cached, do: add_cached_table(state, table.name), else: state
    {:reply, :ok, state}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, :ok, sweep_all(state)}
  end

  def handle_call({:generic_put, table, key, value}, _from, state) do
    case write(state, state.backend_state, table, key, value, :put) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:generic_put_new, table, key, value}, _from, state) do
    case state.backend.put_new(state.backend_state, table, key, value) do
      {:ok, backend_state} ->
        mirror_put(state, table, key, value)
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
    case state.backend.get(state.backend_state, table, key) do
      {:ok, current, backend_state} when current === expected ->
        case write(state, backend_state, table, key, replacement, :compare_and_swap) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
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

  def handle_call({:generic_update, table, key, default, fun}, _from, state) do
    case apply_update(state, table, key, default, fun) do
      {:ok, value, state} -> {:reply, {:ok, value}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:generic_fetch, table, key}, _from, state) do
    case state.backend.get(state.backend_state, table, key) do
      {:ok, nil, backend_state} ->
        {:reply, :error, %{state | backend_state: backend_state}}

      {:ok, value, backend_state} ->
        # Populate the mirror on the way out, from the process that owns it.
        mirror_put(state, table, key, value)
        {:reply, {:ok, value}, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:fetch, table, key, reason)
        {:reply, {:error, reason}, state}

      other ->
        log_backend_unexpected(:fetch, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  def handle_call({:generic_delete, table, key}, _from, state) do
    case state.backend.delete(state.backend_state, table, key) do
      {:ok, backend_state} ->
        mirror_delete(state, table, key)
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
            mirror_delete(state, table, key)
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

  def handle_call({:generic_list_recent, table, limit}, _from, state) do
    if function_exported?(state.backend, :list_recent, 3) do
      case state.backend.list_recent(state.backend_state, table, limit) do
        {:ok, entries, backend_state} ->
          {:reply, {:ok, entries}, %{state | backend_state: backend_state}}

        {:error, reason} ->
          log_backend_error(:list_recent, table, :all, reason)
          {:reply, {:error, reason}, state}

        other ->
          log_backend_unexpected(:list_recent, table, :all, other)
          {:reply, {:error, {:unexpected_backend_response, other}}, state}
      end
    else
      {:reply, {:error, :unsupported}, state}
    end
  end

  @impl true
  def handle_cast({:generic_put_async, table, key, value}, state) do
    case write(state, state.backend_state, table, key, value, :put_async) do
      {:ok, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  def handle_cast({:generic_update_async, table, key, default, fun}, state) do
    case apply_update(state, table, key, default, fun) do
      {:ok, _value, state} -> {:noreply, state}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    state = sweep_all(state)
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  # Writes

  # Backend first, mirror second: the cache never advertises a value the
  # backend rejected. Failures are logged here, once, whatever the caller does
  # with the answer.
  defp write(state, backend_state, table, key, value, op) do
    case state.backend.put(backend_state, table, key, value) do
      {:ok, backend_state} ->
        mirror_put(state, table, key, value)
        {:ok, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(op, table, key, reason)
        {:error, reason, %{state | backend_state: backend_state}}

      other ->
        log_backend_unexpected(op, table, key, other)
        {:error, {:unexpected_backend_response, other}, %{state | backend_state: backend_state}}
    end
  end

  defp apply_update(state, table, key, default, fun) do
    case state.backend.get(state.backend_state, table, key) do
      {:ok, current, backend_state} ->
        input = if is_nil(current), do: default, else: current

        case run_update_fun(fun, input, table, key) do
          {:ok, value} ->
            case write(state, backend_state, table, key, value, :update) do
              {:ok, state} -> {:ok, value, state}
              {:error, reason, state} -> {:error, reason, state}
            end

          {:error, reason} ->
            {:error, reason, %{state | backend_state: backend_state}}
        end

      {:error, reason} ->
        log_backend_error(:update, table, key, reason)
        {:error, reason, state}

      other ->
        log_backend_unexpected(:update, table, key, other)
        {:error, {:unexpected_backend_response, other}, state}
    end
  end

  defp run_update_fun(fun, input, table, key) do
    {:ok, fun.(input)}
  rescue
    exception ->
      Logger.error(
        "[LemonCore.Store] update function raised table=#{inspect(table)} key=#{inspect(key)}:\n" <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:update_failed, exception}}
  end

  defp mirror_put(state, table, key, value) do
    if table in state.cached_tables do
      ReadCache.put(state.read_cache, table, key, value)
    end

    :ok
  end

  defp mirror_delete(state, table, key) do
    if table in state.cached_tables do
      ReadCache.delete(state.read_cache, table, key)
    end

    :ok
  end

  defp add_cached_table(state, table) do
    if table in state.cached_tables do
      state
    else
      read_cache = ReadCache.add_table(state.name, state.read_cache, table)
      cached_tables = state.cached_tables ++ [table]

      backend_state =
        warm_cached_tables(state.backend, state.backend_state, read_cache, [table])

      # Publish after warming, for the reason given in `init/1`.
      Hooks.publish(state.name, :cached_tables, cached_tables)

      %{
        state
        | read_cache: read_cache,
          cached_tables: cached_tables,
          backend_state: backend_state
      }
    end
  end

  # Retention

  defp sweep_all(state) do
    backend_state =
      Enum.reduce(state.tables, state.backend_state, fn {_name, table}, acc ->
        sweep_table(state, acc, table)
      end)

    %{state | backend_state: backend_state}
  end

  defp sweep_table(_state, backend_state, %Table{retention: nil}), do: backend_state

  defp sweep_table(state, backend_state, %Table{name: name} = table) do
    case state.backend.list(backend_state, name) do
      {:ok, entries, backend_state} ->
        now = System.system_time(:millisecond)

        Enum.reduce(entries, backend_state, fn {key, value}, acc ->
          if expired?(table, key, value, now) do
            sweep_delete(state, acc, name, key)
          else
            acc
          end
        end)

      {:error, reason} ->
        log_backend_error(:sweep, name, :all, reason)
        backend_state

      other ->
        log_backend_unexpected(:sweep, name, :all, other)
        backend_state
    end
  end

  # A retention timestamp function belongs to the owner; if it raises, the
  # entry is kept and the failure is logged, so one bad declaration cannot
  # take the store down or delete what it could not date.
  defp expired?(table, key, value, now) do
    Hooks.safely(fn -> Table.expired?(table, key, value, now) end, false,
      op: :retention,
      table: table.name,
      key: key
    )
  end

  # Every sweeper evicts what it deletes. `ReadCache.delete/3` is a no-op for a
  # table this store does not mirror, so the call is unconditional.
  defp sweep_delete(state, backend_state, table, key) do
    case state.backend.delete(backend_state, table, key) do
      {:ok, next_state} ->
        ReadCache.delete(state.read_cache, table, key)
        next_state

      {:error, reason} ->
        log_backend_error(:sweep, table, key, reason)
        backend_state

      other ->
        log_backend_unexpected(:sweep, table, key, other)
        backend_state
    end
  end

  defp log_backend_error(op, table, key, reason) do
    Logger.warning(
      "[LemonCore.Store] backend #{op} failed table=#{inspect(table)} key=#{inspect(key)} " <>
        "reason=#{inspect(reason)}"
    )
  end

  defp log_backend_unexpected(op, table, key, response) do
    Logger.warning(
      "[LemonCore.Store] backend #{op} returned unexpected response table=#{inspect(table)} " <>
        "key=#{inspect(key)} response=#{inspect(response)}"
    )
  end
end
