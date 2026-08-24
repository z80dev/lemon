defmodule LemonMemory.Providers do
  @moduledoc """
  Supervised registry and fan-out search boundary for memory providers.

  Lemon always includes the local SQLite provider. Additional BEAM providers can
  register at runtime and are queried through this module, which gives the agent
  one stable memory-search surface while keeping external providers isolated by
  timeout and exception handling.

  ## Isolation

  Memory is an accessory to a turn, never the point of one, so a provider must
  not be able to slow a turn past its own declared budget or take the turn with
  it when it fails. Each enabled provider therefore runs in its own process —
  spawned with a monitor and deliberately *without* a link — and is awaited
  against its own `:timeout_ms`:

    * **Slowness is per provider.** A provider is dropped when *it* passes its
      own deadline. Registering a provider that declares a generous budget does
      not extend anybody else's: the local SQLite provider stays on its 2s bound
      no matter what else is registered.

    * **Failure is per provider.** A provider that raises, throws or exits is
      converted into a logged failure by the call wrapper. A provider process
      that dies for a reason the wrapper never sees — killed by a third party,
      or killed by an abnormal exit from something the provider itself linked to
      — is observed through the monitor and logged the same way. Either way the
      caller keeps every other provider's results.

  The missing link is the load-bearing part. `Task.async_stream/3` links its
  tasks to the caller, so a provider process killed from outside would deliver
  an exit signal to whoever ran the fan-out: an agent turn on the `search/2`
  path, and this GenServer on the `put/2` path — where a restart would reset
  `state.providers` and silently drop every runtime registration until the
  owning application registered again. A monitor carries the same information
  without that back-propagation.

  ## Known gaps

    * **Total search latency is still bounded by the slowest *enabled*
      provider.** Fan-out is synchronous: `search/2` returns once every provider
      has answered or hit its own deadline, so a provider that declares — and
      uses — 5s makes that one search 5s even though it no longer changes any
      other provider's deadline. Providers are expected to keep budgets small.

    * **A provider that misses its deadline is killed, not asked to stop.** The
      kill is untrappable, so a provider must be safe to abandon mid-call:
      anything that has to finish belongs behind the provider's own supervised
      process, not in the search path.

    * **`put/2` fan-out runs inside this GenServer.** Registration calls queue
      behind it for as long as the slowest enabled provider's timeout. That is a
      bounded stall rather than a failure, but it is why `put/2` budgets matter.

    * **The caller enforces the deadline, so a caller that dies first orphans
      its providers.** Abandon a turn mid-search — an abort, a crash — and the
      provider processes it started keep running until they return on their own.
      No link means they cannot take anything with them, and nothing waits on
      them; a provider that never returns is the only way this leaks, which is
      the same thing that would make its own deadline useless.
  """

  use GenServer
  require Logger

  alias LemonMemory.Document
  alias LemonMemory.Providers.Local

  @local_id "local"
  @default_timeout_ms 2_000

  @type provider_spec :: %{
          required(:id) => String.t(),
          required(:module) => module(),
          optional(:enabled) => boolean(),
          optional(:label) => String.t(),
          optional(:source) => String.t(),
          optional(:scopes) => [atom()],
          optional(:timeout_ms) => non_neg_integer()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register or replace a BEAM memory provider.
  """
  @spec register_provider(provider_spec() | keyword()) :: :ok | {:error, term()}
  def register_provider(spec), do: register_provider(__MODULE__, spec)

  @spec register_provider(GenServer.server(), provider_spec() | keyword()) ::
          :ok | {:error, term()}
  def register_provider(server, spec) do
    case normalize_spec(spec) do
      {:ok, normalized} -> GenServer.call(server, {:register_provider, normalized})
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Remove a registered provider. The built-in local provider cannot be removed.
  """
  @spec unregister_provider(String.t()) :: :ok | {:error, term()}
  def unregister_provider(id), do: unregister_provider(__MODULE__, id)

  @spec unregister_provider(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def unregister_provider(server, id) when is_binary(id) do
    GenServer.call(server, {:unregister_provider, id})
  end

  @doc """
  Returns redacted provider metadata suitable for operators and support bundles.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    specs = Keyword.get(opts, :provider_specs) || provider_specs()
    status_from_specs(specs)
  end

  @doc """
  Fan out a memory document to enabled providers.

  The call is fire-and-forget. Providers are invoked inside this GenServer and
  failures are logged but never returned to callers finalizing a run.
  """
  @spec put(Document.t(), keyword()) :: :ok
  def put(%Document{} = doc, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:put, doc, opts})
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Search enabled providers and return merged memory documents.
  """
  @spec search(binary(), keyword()) :: [Document.t()]
  def search(query, opts \\ []) when is_binary(query) do
    scope = Keyword.get(opts, :scope, :session)
    limit = Keyword.get(opts, :limit, 5)
    specs = Keyword.get(opts, :provider_specs) || provider_specs()

    specs
    |> Enum.filter(&provider_enabled_for_scope?(&1, scope))
    |> run_providers(&call_provider(&1, query, opts))
    |> Enum.flat_map(&search_docs/1)
    |> merge_results(limit)
  end

  @impl true
  def init(_opts) do
    {:ok, %{providers: %{}}}
  end

  @impl true
  def handle_call({:register_provider, %{id: @local_id}}, _from, state) do
    {:reply, {:error, :reserved_provider_id}, state}
  end

  def handle_call({:register_provider, spec}, _from, state) do
    {:reply, :ok, put_in(state.providers[spec.id], spec)}
  end

  def handle_call({:unregister_provider, @local_id}, _from, state) do
    {:reply, {:error, :reserved_provider_id}, state}
  end

  def handle_call({:unregister_provider, id}, _from, state) do
    {:reply, :ok, update_in(state.providers, &Map.delete(&1, id))}
  end

  def handle_call(:provider_specs, _from, state) do
    {:reply, default_specs() ++ Map.values(state.providers), state}
  end

  @impl true
  def handle_cast({:put, %Document{} = doc, opts}, state) do
    (default_specs() ++ Map.values(state.providers))
    |> Enum.filter(&provider_enabled_for_scope?(&1, doc.scope))
    |> run_providers(&call_provider_put(&1, doc, opts))
    |> Enum.each(&log_put_outcome/1)

    {:noreply, state}
  end

  defp provider_specs do
    GenServer.call(__MODULE__, :provider_specs, 1_000)
  catch
    :exit, _ -> default_specs()
  end

  defp default_specs do
    [
      %{
        id: @local_id,
        module: Local,
        enabled: true,
        label: "Local SQLite memory",
        source: "builtin",
        scopes: [:session, :agent, :workspace, :all],
        timeout_ms: @default_timeout_ms
      }
    ]
  end

  defp search_docs({_spec, {:ok, {:ok, docs}}}), do: docs

  defp search_docs({spec, {:ok, {:error, reason}}}) do
    Logger.warning("[Providers] provider #{spec.id} failed: #{inspect(reason)}")
    []
  end

  defp search_docs({spec, {:exit, reason}}) do
    Logger.warning("[Providers] provider #{spec.id} task failed: #{inspect(reason)}")
    []
  end

  defp log_put_outcome({_spec, {:ok, :ok}}), do: :ok

  defp log_put_outcome({spec, {:ok, {:error, reason}}}) do
    Logger.warning("[Providers] provider #{spec.id} put failed: #{inspect(reason)}")
  end

  defp log_put_outcome({spec, {:exit, reason}}) do
    Logger.warning("[Providers] provider #{spec.id} put task failed: #{inspect(reason)}")
  end

  # Runs `fun` for every spec concurrently and returns `[{spec, outcome}]` in the
  # order the specs were given, where outcome is `{:ok, fun_result}` or
  # `{:exit, reason}`.
  #
  # Each provider gets its own monitored, *unlinked* process. The monitor
  # reports a death the same way a link would but does not send the exit signal
  # onwards, which is what keeps a provider process killed from outside from
  # taking down the agent turn (search) or this registry (put). Owning the wait
  # here is also what makes `:timeout_ms` a real per-provider bound:
  # `Task.async_stream/3` takes a single timeout for the whole stream, so the
  # most generous registered provider quietly became everybody else's deadline.
  defp run_providers(specs, fun) when is_function(fun, 1) do
    started_at_ms = System.monotonic_time(:millisecond)

    specs
    |> Enum.map(fn spec -> {spec, start_provider(fn -> fun.(spec) end)} end)
    |> await_providers(started_at_ms)
  end

  # Deadlines are absolute — measured from the instant the workers were spawned,
  # not from when we get around to each one — and are awaited tightest-first, so
  # the wait we are already inside is never longer than the next provider's
  # remaining budget. That is what drops each provider at its own bound. The
  # caller's order is restored afterwards to keep merging deterministic.
  defp await_providers(workers, started_at_ms) do
    workers
    |> Enum.with_index()
    |> Enum.sort_by(fn {{spec, _worker}, index} -> {timeout_ms(spec), index} end)
    |> Enum.map(fn {{spec, worker}, index} ->
      elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms
      {index, {spec, await_provider(worker, timeout_ms(spec) - elapsed_ms)}}
    end)
    |> Enum.sort_by(fn {index, _outcome} -> index end)
    |> Enum.map(fn {_index, outcome} -> outcome end)
  end

  defp start_provider(fun) do
    owner = self()
    ref = make_ref()

    {pid, monitor_ref} = spawn_monitor(fn -> send(owner, {ref, fun.()}) end)

    %{pid: pid, ref: ref, monitor_ref: monitor_ref}
  end

  defp await_provider(%{pid: pid, ref: ref, monitor_ref: monitor_ref} = worker, remaining_ms) do
    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:exit, reason}
    after
      max(remaining_ms, 0) -> kill_provider(worker)
    end
  end

  # A provider past its deadline is killed rather than asked to stop: it is
  # blocked in its own code and cannot be reasoned with. The reply may have been
  # sent in the window between the deadline firing and the kill landing, so
  # prefer an answer we already hold over discarding work. Otherwise the monitor
  # is guaranteed to fire — we just killed the process — so this receive always
  # terminates, and because a reply is always sent before the process exits,
  # either branch leaves the caller's mailbox clean.
  defp kill_provider(%{pid: pid, ref: ref, monitor_ref: monitor_ref}) do
    Process.exit(pid, :kill)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, result}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:exit, :timeout}
    end
  end

  defp call_provider(spec, query, opts) do
    module = spec.module
    provider_opts = Keyword.put(opts, :provider_id, spec.id)

    case module.search(query, provider_opts) do
      docs when is_list(docs) -> {:ok, Enum.filter(docs, &match?(%Document{}, &1))}
      other -> {:error, {:invalid_result, other}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp call_provider_put(spec, %Document{} = doc, opts) do
    module = spec.module
    provider_opts = Keyword.put(opts, :provider_id, spec.id)

    if Code.ensure_loaded?(module) and function_exported?(module, :put, 2) do
      case module.put(doc, provider_opts) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_result, other}}
      end
    else
      {:error, :put_not_supported}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp merge_results(docs, limit) do
    docs
    |> Enum.uniq_by(& &1.doc_id)
    |> Enum.sort_by(&(&1.ingested_at_ms || 0), :desc)
    |> Enum.take(limit)
  end

  defp provider_enabled_for_scope?(spec, scope) do
    Map.get(spec, :enabled, true) and
      scope in Map.get(spec, :scopes, [:session, :agent, :workspace, :all])
  end

  defp timeout_ms(spec) do
    case Map.get(spec, :timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_timeout_ms
    end
  end

  defp status_from_specs(specs) do
    enabled = Enum.filter(specs, &Map.get(&1, :enabled, true))

    %{
      provider_count: length(specs),
      enabled_provider_count: length(enabled),
      providers: Enum.map(specs, &redacted_provider/1),
      cleanup: %{
        includes_memory_contents: false,
        includes_raw_provider_config: false,
        includes_secret_values: false
      }
    }
  end

  defp redacted_provider(spec) do
    %{
      id: spec.id,
      enabled: Map.get(spec, :enabled, true),
      source: Map.get(spec, :source, "runtime"),
      scopes: spec |> Map.get(:scopes, []) |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      timeout_ms: Map.get(spec, :timeout_ms, @default_timeout_ms),
      module_loaded: Code.ensure_loaded?(spec.module)
    }
  end

  defp normalize_spec(spec) when is_list(spec), do: spec |> Map.new() |> normalize_spec()

  defp normalize_spec(spec) when is_map(spec) do
    with {:ok, id} <- normalize_id(Map.get(spec, :id) || Map.get(spec, "id")),
         {:ok, module} <- normalize_module(Map.get(spec, :module) || Map.get(spec, "module")) do
      {:ok,
       %{
         id: id,
         module: module,
         enabled: Map.get(spec, :enabled, Map.get(spec, "enabled", true)) != false,
         label: normalize_optional_string(Map.get(spec, :label) || Map.get(spec, "label")),
         source:
           normalize_optional_string(Map.get(spec, :source) || Map.get(spec, "source")) ||
             "runtime",
         scopes: normalize_scopes(Map.get(spec, :scopes) || Map.get(spec, "scopes")),
         timeout_ms: normalize_timeout(Map.get(spec, :timeout_ms) || Map.get(spec, "timeout_ms"))
       }}
    end
  end

  defp normalize_spec(_), do: {:error, :invalid_provider_spec}

  defp normalize_id(id) when is_binary(id) do
    id = String.trim(id)

    if id == "" do
      {:error, :invalid_provider_id}
    else
      {:ok, id}
    end
  end

  defp normalize_id(id) when is_atom(id), do: normalize_id(Atom.to_string(id))
  defp normalize_id(_), do: {:error, :invalid_provider_id}

  defp normalize_module(module) when is_atom(module), do: {:ok, module}
  defp normalize_module(_), do: {:error, :invalid_provider_module}

  defp normalize_scopes(nil), do: [:session, :agent, :workspace, :all]

  defp normalize_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&normalize_scope/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> [:session, :agent, :workspace, :all]
      scopes -> Enum.uniq(scopes)
    end
  end

  defp normalize_scopes(_), do: [:session, :agent, :workspace, :all]

  defp normalize_scope(scope) when scope in [:session, :agent, :workspace, :all], do: scope
  defp normalize_scope("session"), do: :session
  defp normalize_scope("agent"), do: :agent
  defp normalize_scope("workspace"), do: :workspace
  defp normalize_scope("all"), do: :all
  defp normalize_scope(_), do: nil

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout(_), do: @default_timeout_ms

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_optional_string(_), do: nil
end
