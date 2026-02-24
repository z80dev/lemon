defmodule LemonCore.Store.ReadCache do
  @moduledoc """
  Public ETS read-through cache for high-traffic Store domains.

  This module maintains a set of public ETS tables that mirror the backing
  store for domains that receive heavy read traffic (chat state, runs,
  progress mappings, session index, Telegram target index). Reads are served directly from ETS without going
  through the Store GenServer, eliminating mailbox contention on the
  read path.

  Writes still go through the Store GenServer, which updates both the
  backend and this cache atomically within its process.

  ## Cached Domains

  - `:chat` — chat state by scope
  - `:runs` — run records by run_id
  - `:progress` — progress mappings by {scope, msg_id}
  - `:sessions_index` — durable session metadata by session key
  - `:telegram_known_targets` — known Telegram targets by {account_id, chat_id, topic_id}

  ## Usage

  Callers should use `get/2` for reads. The Store GenServer calls
  `put/3` and `delete/2` to keep the cache in sync with the backend.
  """

  @cached_domains [:chat, :runs, :progress, :sessions_index, :telegram_known_targets]

  @doc """
  Initialize the cache ETS tables. Called once during Store init.
  """
  @spec init() :: :ok
  def init do
    for domain <- @cached_domains do
      table_name = table_for(domain)

      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [
            :named_table,
            :public,
            :set,
            read_concurrency: true
          ])

        _tid ->
          :ok
      end
    end

    :ok
  end

  @doc """
  Check whether a domain is cached.
  """
  @spec cached?(atom()) :: boolean()
  def cached?(domain), do: domain in @cached_domains

  @doc """
  Read a value from the cache. Returns `nil` if not found.

  This bypasses the GenServer entirely for O(1) ETS lookup.
  """
  @spec get(atom(), term()) :: term() | nil
  def get(domain, key) when domain in @cached_domains do
    table = table_for(domain)

    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def get(_domain, _key), do: nil

  @doc """
  Update the cache after a backend write. Called by the Store GenServer.
  """
  @spec put(atom(), term(), term()) :: :ok
  def put(domain, key, value) when domain in @cached_domains do
    table = table_for(domain)
    :ets.insert(table, {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(_domain, _key, _value), do: :ok

  @doc """
  Remove an entry from the cache. Called by the Store GenServer.
  """
  @spec delete(atom(), term()) :: :ok
  def delete(domain, key) when domain in @cached_domains do
    table = table_for(domain)
    :ets.delete(table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def delete(_domain, _key), do: :ok

  @doc """
  Return the ETS table name for a domain.
  """
  @spec table_for(atom()) :: atom()
  def table_for(:chat), do: :lemon_store_cache_chat
  def table_for(:runs), do: :lemon_store_cache_runs
  def table_for(:progress), do: :lemon_store_cache_progress
  def table_for(:sessions_index), do: :lemon_store_cache_sessions_index
  def table_for(:telegram_known_targets), do: :lemon_store_cache_telegram_known_targets

  @doc """
  List all cached entries for a domain as `{key, value}` tuples.
  """
  @spec list(atom()) :: [{term(), term()}]
  def list(domain) when domain in @cached_domains do
    table = table_for(domain)
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end

  def list(_domain), do: []

  @doc """
  List of domains that are cached.
  """
  @spec cached_domains() :: [atom()]
  def cached_domains, do: @cached_domains
end
