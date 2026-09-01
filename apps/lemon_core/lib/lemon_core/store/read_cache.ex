defmodule LemonCore.Store.ReadCache.CollisionError do
  @moduledoc """
  Raised when a `LemonCore.Store.ReadCache` ETS table already exists but is
  owned by a process that is not the store instance claiming it.
  """

  defexception [:message]
end

defmodule LemonCore.Store.ReadCache do
  @moduledoc """
  Public ETS read-through cache for high-traffic Store domains.

  This module maintains a set of public ETS tables that mirror the backing
  store for domains that receive heavy read traffic (chat state, runs,
  progress mappings, session index, and whatever tables collaborators register
  through `register_cached_table/1`). Reads are served directly from ETS
  without going through the Store GenServer, eliminating mailbox contention on
  the read path.

  Writes still go through the Store GenServer, which updates both the
  backend and this cache atomically within its process.

  ## Cached Domains

  Intrinsic domains, mirrored for the store's own typed APIs:

  - `:chat` — chat state by scope
  - `:runs` — run records by run_id
  - `:progress` — progress mappings by {scope, msg_id}

  Generic tables are added per store instance — `:sessions_index` by default,
  plus whatever owners register with `LemonCore.Store.register_cached_table/2`.
  The store does not know what those tables hold.

  ## Instances

  Every cache is scoped to the name of the `LemonCore.Store` that owns it.
  The default store (`LemonCore.Store`) keeps the historical table names
  (`:lemon_store_cache_chat` and friends); any other store name gets its own
  prefixed set, so several stores can run in one node without sharing data.

  `init/1` returns a map of `domain => table reference`. The owning Store keeps
  that map in its state and passes it back on the server side; client-side
  callers pass the store *name* and the table references are resolved from
  `:persistent_term` instead of being rebuilt from atoms on every call.

  ## Usage

  Callers should use `get/2` for reads. The Store GenServer calls
  `put/3` and `delete/2` to keep the cache in sync with the backend.
  """

  require Logger

  alias LemonCore.Store.ReadCache.CollisionError

  @default_store LemonCore.Store

  @type store :: atom()
  @type tables :: %{optional(atom()) => :ets.table()}

  @doc """
  Initialize the cache ETS tables for `store`. Called during Store init.

  Creates a table for each intrinsic domain plus each of `generic_tables`, and
  publishes the `domain => table` map to `:persistent_term` so client processes
  can resolve tables without re-deriving atom names.

  Additive: domains already published for this store whose tables are still
  alive are carried over, so a caller that re-initializes with a smaller set
  never silently strips another caller's tables out of the shared map.

  Raises `LemonCore.Store.ReadCache.CollisionError` when a table with the
  derived name already exists and is owned by a process other than this store
  instance — silently reusing another instance's table would merge two stores'
  data.
  """
  @spec init(store(), [atom()]) :: tables()
  def init(store \\ @default_store, generic_tables \\ [])

  def init(store, generic_tables) when is_atom(store) and not is_nil(store) do
    domains = Enum.uniq(generic_tables ++ live_published_domains(store))
    tables = Map.new(domains, fn domain -> {domain, ensure_table(store, domain)} end)
    publish(store, tables)
    tables
  end

  @doc """
  Add one generic table to a store's cache and return the updated map.

  Must be called from the process that owns the store's tables.
  """
  @spec add_table(store(), tables(), atom()) :: tables()
  def add_table(store, tables, domain) when is_map(tables) and is_atom(domain) do
    updated = Map.put_new_lazy(tables, domain, fn -> ensure_table(store, domain) end)
    publish(store, updated)
    updated
  end

  @doc """
  List the domains this store currently caches.
  """
  @spec cached_domains(store()) :: [atom()]
  def cached_domains(store \\ @default_store) do
    case tables(store) do
      nil -> []
      tables -> Map.keys(tables)
    end
  end

  @doc """
  Return the published `domain => table` map for a store, or `nil` when the
  store has never initialized its cache.
  """
  @spec tables(store()) :: tables() | nil
  def tables(store) when is_atom(store), do: :persistent_term.get(pt_key(store), nil)
  def tables(_store), do: nil

  @doc """
  Check whether `store` currently caches `domain`.
  """
  @spec cached?(store() | tables(), atom()) :: boolean()
  def cached?(store \\ @default_store, domain), do: resolve(store, domain) != nil

  @doc """
  Read a value from the cache. Returns `nil` if not found.

  This bypasses the GenServer entirely for O(1) ETS lookup.
  """
  @spec get(store() | tables(), atom(), term()) :: term() | nil
  def get(store \\ @default_store, domain, key)

  def get(store, domain, key) do
    case fetch(store, domain, key) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  @doc """
  Read a value, distinguishing "not cached" from "cached but absent".

  Returns `:uncached` when the store does not mirror `domain` at all, `:miss`
  when it does but has no entry for `key`, and `{:ok, value}` on a hit. Callers
  use this to decide whether a cache miss is worth populating.
  """
  @spec fetch(store() | tables(), atom(), term()) :: {:ok, term()} | :miss | :uncached
  def fetch(store \\ @default_store, domain, key) do
    case resolve(store, domain) do
      nil ->
        :uncached

      table ->
        case :ets.lookup(table, key) do
          [{^key, value}] -> {:ok, value}
          _ -> :miss
        end
    end
  rescue
    ArgumentError -> :uncached
  end

  @doc """
  Update the cache after a backend write. Called by the Store GenServer.
  """
  @spec put(store() | tables(), atom(), term(), term()) :: :ok
  def put(store \\ @default_store, domain, key, value)

  def put(store, domain, key, value) do
    case resolve(store, domain) do
      nil -> :ok
      table -> :ets.insert(table, {key, value})
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Remove an entry from the cache. Called by the Store GenServer.
  """
  @spec delete(store() | tables(), atom(), term()) :: :ok
  def delete(store \\ @default_store, domain, key)

  def delete(store, domain, key) do
    case resolve(store, domain) do
      nil -> :ok
      table -> :ets.delete(table, key)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Return the ETS table name for a domain of a store instance.

  The default store keeps the historical names; other instances are prefixed
  with their (underscored) store name.
  """
  @spec table_for(store(), atom()) :: atom()
  def table_for(store \\ @default_store, domain)

  def table_for(@default_store, domain) when is_atom(domain) and not is_nil(domain),
    do: :"lemon_store_cache_#{domain}"

  def table_for(store, domain)
      when is_atom(store) and not is_nil(store) and is_atom(domain) and not is_nil(domain) do
    :"lemon_store_cache_#{store_prefix(store)}_#{domain}"
  end

  @doc """
  List all cached entries for a domain as `{key, value}` tuples.
  """
  @spec list(store() | tables(), atom()) :: [{term(), term()}]
  def list(store \\ @default_store, domain)

  def list(store, domain) do
    case resolve(store, domain) do
      nil -> []
      table -> :ets.tab2list(table)
    end
  rescue
    ArgumentError -> []
  end

  # -- Internals -----------------------------------------------------------

  # Server-side callers pass the table map straight through; client-side
  # callers pass the store name and we look the map up once.
  defp resolve(tables, domain) when is_map(tables), do: Map.get(tables, domain)

  # Deliberately no fallback to a derived table name: deriving atoms from
  # caller-supplied table names would leak atoms, and a store that has not
  # published a map has no live tables anyway.
  defp resolve(store, domain) when is_atom(store) and not is_nil(store) do
    case :persistent_term.get(pt_key(store), nil) do
      nil -> nil
      tables -> Map.get(tables, domain)
    end
  end

  defp resolve(_store, _domain), do: nil

  defp pt_key(store), do: {__MODULE__, store}

  defp publish(store, tables) do
    key = pt_key(store)

    # persistent_term writes trigger a global GC scan; skip the no-op case so
    # repeated init/1 calls (tests, store restarts onto live tables) are cheap.
    if :persistent_term.get(key, nil) != tables do
      :persistent_term.put(key, tables)
    end

    :ok
  end

  defp ensure_table(store, domain) do
    name = table_for(store, domain)

    case :ets.whereis(name) do
      :undefined -> new_table(name)
      tid -> claim_existing_table!(store, name, tid, domain)
    end
  end

  # Tables are named for observability, but the map holds table *references*:
  # `:ets.new/2` hands back the name for a named table, so ask for the ref, and
  # every entry in the map is then the same shape whether it was freshly
  # created or re-attached to.
  defp new_table(name) do
    _ = :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    :ets.whereis(name)
  end

  # A live named table can legitimately belong to this instance: `init/1` is
  # idempotent within the owning process, and callers (tests, the Store's own
  # re-init) may re-attach to the tables owned by the registered store process.
  # Anything else is two stores fighting over one table — fail loudly, since
  # reusing it would silently merge their data.
  defp claim_existing_table!(store, name, tid, domain) do
    case :ets.info(tid, :owner) do
      :undefined ->
        new_table(name)

      owner when owner == self() ->
        tid

      owner ->
        registered = Process.whereis(store)

        if is_pid(registered) and owner == registered do
          tid
        else
          message =
            "ReadCache table #{inspect(name)} (domain #{inspect(domain)}) for store " <>
              "#{inspect(store)} already exists and is owned by #{inspect(owner)}, which is " <>
              "not that store instance (registered: #{inspect(registered)}). Give the store a " <>
              "distinct :name so it gets its own cache tables."

          Logger.error("[LemonCore.Store.ReadCache] #{message}")
          raise CollisionError, message: message
        end
    end
  end

  # Domains already published for this store whose tables are still alive. Dead
  # entries are dropped so a restarted store rebuilds them instead of
  # republishing references to tables that died with the previous owner.
  defp live_published_domains(store) do
    case tables(store) do
      nil ->
        []

      published ->
        for {domain, _ref} <- published,
            :ets.whereis(table_for(store, domain)) != :undefined,
            do: domain
    end
  end

  defp store_prefix(store) do
    case Atom.to_string(store) do
      "Elixir." <> rest -> rest |> String.replace(".", "_") |> Macro.underscore()
      other -> other
    end
  end
end
