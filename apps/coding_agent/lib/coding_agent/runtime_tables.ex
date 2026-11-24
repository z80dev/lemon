defmodule CodingAgent.RuntimeTables do
  @moduledoc """
  Supervised owner of disposable extension, web and capability caches.

  Production tables exist before sessions start. Additional web-cache tables are
  created synchronously by this owner, never by a tool task. Callers require the
  coding_agent application to be running; they do not start fallback owners.

  Cache reads use ETS directly. Capability probes run in the requesting process,
  not the owner; concurrent misses may probe more than once, but publication is
  first-writer-wins and every caller receives the published value. Owner restart
  discards volatile entries, including the fallback secret-placeholder key.

  It is also the ETS heir of every `CodingAgent.DurableTable` mirror. A crashed
  durable owner's live table transfers here and `reclaim/1` hands it to the
  restarted owner, so a store restart does not lose in-flight state.
  """

  use GenServer

  @cache_table :coding_agent_runtime_cache
  @tables [
    :coding_agent_tool_registry_extension_cache,
    :coding_agent_extension_source_paths,
    :coding_agent_extension_load_errors,
    :coding_agent_extension_module_owners,
    :coding_agent_extension_poisoned_modules,
    :coding_agent_extension_providers,
    :coding_agent_web_cache_state,
    :coding_agent_websearch_cache,
    :coding_agent_webfetch_cache,
    :coding_agent_websearch_rate_limit
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def available?, do: :ets.whereis(@cache_table) != :undefined

  @doc false
  def ensure_table(table) do
    case :ets.whereis(table) do
      :undefined -> GenServer.call(__MODULE__, {:ensure_table, table})
      tid -> tid
    end
  end

  @doc false
  def fetch(key, compute) when is_function(compute, 0) do
    case :ets.lookup(@cache_table, key) do
      [{^key, value}] -> value
      [] -> GenServer.call(__MODULE__, {:put_new, key, compute.()})
    end
  end

  @doc false
  def delete(key), do: GenServer.call(__MODULE__, {:delete, key})

  @doc """
  Give an inherited durable mirror back to the calling owner. Returns `:none`
  when this process does not hold `table` (first boot, clean stop or a table
  owned by another live process).
  """
  @spec reclaim(atom()) :: :ok | :none
  def reclaim(table) when is_atom(table) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) and pid != self() -> GenServer.call(pid, {:reclaim, table})
      _ -> :none
    end
  end

  @impl true
  def init(opts) do
    Enum.each(Keyword.get(opts, :tables, @tables), &new_table/1)
    cache_table = Keyword.get(opts, :cache_table, @cache_table)
    :ets.new(cache_table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, cache_table}
  end

  @impl true
  def handle_call({:ensure_table, table}, _from, state) do
    tid =
      case :ets.whereis(table) do
        :undefined -> new_table(table)
        tid -> tid
      end

    {:reply, tid, state}
  end

  def handle_call({:put_new, key, value}, _from, cache_table) do
    :ets.insert_new(cache_table, {key, value})
    [{^key, published}] = :ets.lookup(cache_table, key)
    {:reply, published, cache_table}
  end

  def handle_call({:delete, key}, _from, cache_table) do
    :ets.delete(cache_table, key)
    {:reply, :ok, cache_table}
  end

  def handle_call({:reclaim, table}, {owner, _tag}, cache_table) do
    {:reply, give_back(table, owner, 50), cache_table}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _tid, _from, _data}, cache_table), do: {:noreply, cache_table}
  def handle_info(_message, cache_table), do: {:noreply, cache_table}

  # A dead owner's table reaches the heir as part of its exit; a restarted
  # owner can ask before that transfer has completed.
  defp give_back(table, owner, attempts) do
    with tid when tid != :undefined <- :ets.whereis(table),
         current when is_pid(current) <- :ets.info(tid, :owner) do
      cond do
        current == self() ->
          :ets.give_away(tid, owner, :reclaimed)
          :ok

        attempts > 0 and not Process.alive?(current) ->
          Process.sleep(2)
          give_back(table, owner, attempts - 1)

        true ->
          :none
      end
    else
      _ -> :none
    end
  end

  defp new_table(table) do
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
  end
end
