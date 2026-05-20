defmodule LemonCore.MemoryProviders do
  @moduledoc """
  Supervised registry and fan-out search boundary for memory providers.

  Lemon always includes the local SQLite provider. Additional BEAM providers can
  register at runtime and are queried through this module, which gives the agent
  one stable memory-search surface while keeping external providers isolated by
  timeout and exception handling.
  """

  use GenServer
  require Logger

  alias LemonCore.MemoryDocument
  alias LemonCore.MemoryProviders.Local

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
  @spec put(MemoryDocument.t(), keyword()) :: :ok
  def put(%MemoryDocument{} = doc, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.cast(server, {:put, doc, opts})
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Search enabled providers and return merged memory documents.
  """
  @spec search(binary(), keyword()) :: [MemoryDocument.t()]
  def search(query, opts \\ []) when is_binary(query) do
    scope = Keyword.get(opts, :scope, :session)
    limit = Keyword.get(opts, :limit, 5)
    specs = Keyword.get(opts, :provider_specs) || provider_specs()

    specs
    |> Enum.filter(&provider_enabled_for_scope?(&1, scope))
    |> run_provider_searches(query, opts)
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
  def handle_cast({:put, %MemoryDocument{} = doc, opts}, state) do
    specs =
      (default_specs() ++ Map.values(state.providers))
      |> Enum.filter(&provider_enabled_for_scope?(&1, doc.scope))

    Task.async_stream(
      specs,
      fn spec ->
        case call_provider_put(spec, doc, opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("[MemoryProviders] provider #{spec.id} put failed: #{inspect(reason)}")
        end
      end,
      timeout: max_timeout(specs),
      on_timeout: :kill_task
    )
    |> Stream.run()

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

  defp run_provider_searches(specs, query, opts) do
    specs
    |> Task.async_stream(
      fn spec ->
        {spec, call_provider(spec, query, opts)}
      end,
      timeout: max_timeout(specs),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.flat_map(fn
      {:ok, {_spec, {:ok, docs}}} ->
        docs

      {:ok, {spec, {:error, reason}}} ->
        Logger.warning("[MemoryProviders] provider #{spec.id} failed: #{inspect(reason)}")
        []

      {:exit, reason} ->
        Logger.warning("[MemoryProviders] provider task failed: #{inspect(reason)}")
        []
    end)
  end

  defp call_provider(spec, query, opts) do
    module = spec.module
    provider_opts = Keyword.put(opts, :provider_id, spec.id)

    case module.search(query, provider_opts) do
      docs when is_list(docs) -> {:ok, Enum.filter(docs, &match?(%MemoryDocument{}, &1))}
      other -> {:error, {:invalid_result, other}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp call_provider_put(spec, %MemoryDocument{} = doc, opts) do
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

  defp max_timeout([]), do: @default_timeout_ms

  defp max_timeout(specs) do
    specs
    |> Enum.map(&Map.get(&1, :timeout_ms, @default_timeout_ms))
    |> Enum.max()
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
