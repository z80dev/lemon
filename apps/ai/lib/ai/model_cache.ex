defmodule Ai.ModelCache do
  @moduledoc """
  Caches model availability per provider using ETS to reduce redundant API calls.
  Ported from Oh-My-Pi's model-cache.ts (SQLite) to idiomatic Elixir with ETS.
  """

  use GenServer

  @table :ai_model_cache
  @default_ttl 300_000

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec read(term(), non_neg_integer()) ::
          {:ok, %{models: list(), fresh: boolean(), authoritative: boolean(), updated_at: integer()}}
          | :miss
  def read(provider_id, ttl_ms \\ @default_ttl) do
    case :ets.lookup(@table, provider_id) do
      [{^provider_id, models, updated_at, _ttl_ms, authoritative}] ->
        now = System.monotonic_time(:millisecond)
        fresh = now - updated_at < ttl_ms

        {:ok, %{models: models, fresh: fresh, authoritative: authoritative, updated_at: updated_at}}

      [] ->
        :miss
    end
  end

  @spec write(term(), list(), keyword()) :: :ok
  def write(provider_id, models, opts \\ []) do
    authoritative = Keyword.get(opts, :authoritative, false)
    now = System.monotonic_time(:millisecond)
    :ets.insert(@table, {provider_id, models, now, @default_ttl, authoritative})
    :ok
  end

  @spec invalidate(term()) :: :ok
  def invalidate(provider_id) do
    :ets.delete(@table, provider_id)
    :ok
  end

  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @spec stats() :: %{entries: non_neg_integer(), providers: list()}
  def stats do
    entries = :ets.info(@table, :size)

    providers =
      :ets.foldl(fn {provider_id, _models, _updated_at, _ttl, _auth}, acc ->
        [provider_id | acc]
      end, [], @table)

    %{entries: entries, providers: providers}
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table =
      try do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      rescue
        ArgumentError -> @table
      end

    {:ok, %{table: table}}
  end
end
