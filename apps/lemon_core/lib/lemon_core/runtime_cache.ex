defmodule LemonCore.RuntimeCache do
  @moduledoc """
  Supervised ETS storage for core's volatile runtime metadata.

  This owner starts before Store and remains alive across Store restarts. Reads,
  publications and warning claims use ETS directly; ordered list registrations
  are serialized so concurrent collaborators cannot overwrite one another.
  Keys are namespaced by the consuming module. The cache is not durable: an
  owner or application restart clears it, unlike boot-only configuration in
  `:persistent_term`.
  """

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  def get(key, default \\ nil) do
    case :ets.lookup(__MODULE__, key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  @doc false
  def put(key, value) do
    true = :ets.insert(__MODULE__, {key, value})
    :ok
  end

  @doc false
  def register(key, value), do: GenServer.call(__MODULE__, {:register, key, value})

  @doc false
  def unregister(key, value), do: GenServer.call(__MODULE__, {:unregister, key, value})

  @doc "Atomically claim a warning; before startup, always warn without caching."
  def warn_once?(key) do
    :ets.insert_new(__MODULE__, {key, true})
  rescue
    ArgumentError -> true
  end

  @impl true
  def init(_opts) do
    _ = :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:register, key, value}, _from, state) do
    current = get(key, [])
    unless value in current, do: put(key, current ++ [value])
    {:reply, :ok, state}
  end

  def handle_call({:unregister, key, value}, _from, state) do
    put(key, List.delete(get(key, []), value))
    {:reply, :ok, state}
  end
end
