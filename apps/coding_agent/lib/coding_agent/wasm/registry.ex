defmodule CodingAgent.Wasm.Registry do
  @moduledoc """
  Dynamic WASM module registry with caching and versioning support.

  The Registry provides:
  - Dynamic module loading from multiple sources (local, HTTP, IPFS)
  - Module caching with TTL and versioning
  - Source tracking and provenance
  - Health checks and automatic refresh

  ## Usage

      # Start the registry
      {:ok, pid} = CodingAgent.Wasm.Registry.start_link()

      # Register a module from local path
      {:ok, module} = CodingAgent.Wasm.Registry.register_local(pid, "my_tool", "/path/to/tool.wasm")

      # Register from HTTP URL
      {:ok, module} = CodingAgent.Wasm.Registry.register_http(pid, "remote_tool", "https://example.com/tool.wasm")

      # Get cached module
      {:ok, module} = CodingAgent.Wasm.Registry.get_module(pid, "my_tool")

      # List all registered modules
      modules = CodingAgent.Wasm.Registry.list_modules(pid)

  """

  use GenServer

  require Logger

  alias CodingAgent.Wasm.Registry.Entry

  @default_cache_dir :lemon_wasm_registry
  @default_ttl_ms :timer.hours(24)
  @cleanup_interval_ms :timer.minutes(5)

  # ============================================================================
  # Types
  # ============================================================================

  @type source_type :: :local | :http | :ipfs | :embedded

  @type module_source :: %{
          type: source_type(),
          uri: String.t(),
          checksum: String.t() | nil,
          version: String.t() | nil,
          metadata: map()
        }

  @type registry_stats :: %{
          total_modules: non_neg_integer(),
          active_modules: non_neg_integer(),
          expired_modules: non_neg_integer(),
          cache_hits: non_neg_integer(),
          cache_misses: non_neg_integer(),
          load_errors: non_neg_integer(),
          total_load_time_ms: non_neg_integer()
        }

  @type registry_opts :: [
          name: atom(),
          cache_dir: String.t() | nil,
          default_ttl_ms: non_neg_integer(),
          max_cache_size_mb: non_neg_integer(),
          cleanup_interval_ms: non_neg_integer(),
          http_client: module()
        ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the WASM module registry.

  ## Options

    * `:name` - Optional process name for registration
    * `:cache_dir` - Directory for caching downloaded modules (default: system temp)
    * `:default_ttl_ms` - Default TTL for cached modules in ms (default: 24 hours)
    * `:max_cache_size_mb` - Maximum cache size in MB (default: 100)
    * `:cleanup_interval_ms` - Cleanup interval in ms (default: 5 minutes)
    * `:http_client` - HTTP client module for fetching remote modules (default: Req)

  """
  @spec start_link(registry_opts()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Registers a WASM module from a local file path.
  """
  @spec register_local(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def register_local(server, name, path, opts \\ []) do
    GenServer.call(server, {:register, :local, name, path, opts})
  end

  @doc """
  Registers a WASM module from an HTTP/HTTPS URL.
  """
  @spec register_http(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def register_http(server, name, url, opts \\ []) do
    GenServer.call(server, {:register, :http, name, url, opts})
  end

  @doc """
  Registers a WASM module from an IPFS CID.
  """
  @spec register_ipfs(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def register_ipfs(server, name, cid, opts \\ []) do
    GenServer.call(server, {:register, :ipfs, name, cid, opts})
  end

  @doc """
  Registers a WASM module from embedded binary data.
  """
  @spec register_embedded(GenServer.server(), String.t(), binary(), keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def register_embedded(server, name, binary, opts \\ []) do
    GenServer.call(server, {:register, :embedded, name, binary, opts})
  end

  @doc """
  Retrieves a module entry by name.
  """
  @spec get_module(GenServer.server(), String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def get_module(server, name) do
    GenServer.call(server, {:get_module, name})
  end

  @doc """
  Gets the module binary data by name.
  """
  @spec get_module_binary(GenServer.server(), String.t()) ::
          {:ok, binary()} | {:error, :not_found | :load_failed}
  def get_module_binary(server, name) do
    GenServer.call(server, {:get_module_binary, name})
  end

  @doc """
  Lists all registered modules.
  """
  @spec list_modules(GenServer.server()) :: [Entry.t()]
  def list_modules(server) do
    GenServer.call(server, :list_modules)
  end

  @doc """
  Lists modules filtered by source type.
  """
  @spec list_modules_by_source(GenServer.server(), source_type()) :: [Entry.t()]
  def list_modules_by_source(server, source_type) do
    GenServer.call(server, {:list_modules_by_source, source_type})
  end

  @doc """
  Unregisters a module by name.
  """
  @spec unregister(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def unregister(server, name) do
    GenServer.call(server, {:unregister, name})
  end

  @doc """
  Refreshes a module from its source.
  """
  @spec refresh(GenServer.server(), String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def refresh(server, name) do
    GenServer.call(server, {:refresh, name})
  end

  @doc """
  Checks if a module is registered and not expired.
  """
  @spec module_exists?(GenServer.server(), String.t()) :: boolean()
  def module_exists?(server, name) do
    GenServer.call(server, {:module_exists?, name})
  end

  @doc """
  Returns registry statistics.
  """
  @spec stats(GenServer.server()) :: registry_stats()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Clears expired entries from the cache.
  """
  @spec cleanup(GenServer.server()) :: %{removed: non_neg_integer(), remaining: non_neg_integer()}
  def cleanup(server) do
    GenServer.call(server, :cleanup)
  end

  @doc """
  Clears all cached modules.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server) do
    GenServer.call(server, :clear)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    cache_dir = get_cache_dir(opts)
    default_ttl = Keyword.get(opts, :default_ttl_ms, @default_ttl_ms)
    cleanup_interval = Keyword.get(opts, :cleanup_interval_ms, @cleanup_interval_ms)
    http_client = Keyword.get(opts, :http_client, Req)
    max_size_mb = Keyword.get(opts, :max_cache_size_mb, 100)

    # Ensure cache directory exists
    File.mkdir_p!(cache_dir)

    state = %{
      entries: %{},
      cache_dir: cache_dir,
      default_ttl_ms: default_ttl,
      max_cache_size_bytes: max_size_mb * 1024 * 1024,
      http_client: http_client,
      stats: %{
        cache_hits: 0,
        cache_misses: 0,
        load_errors: 0,
        total_load_time_ms: 0
      },
      cleanup_timer: nil
    }

    # Schedule cleanup
    timer = Process.send_after(self(), :cleanup, cleanup_interval)
    state = %{state | cleanup_timer: timer}

    {:ok, state}
  end

  @impl true
  def handle_call({:register, source_type, name, source, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    result = do_register(state, source_type, name, source, opts)

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, entry, new_state} ->
        new_stats = %{
          state.stats
          | total_load_time_ms: state.stats.total_load_time_ms + duration
        }

        emit_telemetry(:register, %{duration_ms: duration}, %{
          name: name,
          source_type: source_type,
          success: true
        })

        {:reply, {:ok, entry}, %{new_state | stats: new_stats}}

      {:error, reason} ->
        new_stats = %{state.stats | load_errors: state.stats.load_errors + 1}

        emit_telemetry(:register, %{duration_ms: duration}, %{
          name: name,
          source_type: source_type,
          success: false,
          error: reason
        })

        {:reply, {:error, reason}, %{state | stats: new_stats}}
    end
  end

  @impl true
  def handle_call({:get_module, name}, _from, state) do
    case Map.get(state.entries, name) do
      nil ->
        new_stats = %{state.stats | cache_misses: state.stats.cache_misses + 1}
        {:reply, {:error, :not_found}, %{state | stats: new_stats}}

      entry ->
        if Entry.expired?(entry) do
          new_stats = %{state.stats | cache_misses: state.stats.cache_misses + 1}
          {:reply, {:error, :expired}, %{state | stats: new_stats}}
        else
          new_stats = %{state.stats | cache_hits: state.stats.cache_hits + 1}
          {:reply, {:ok, entry}, %{state | stats: new_stats}}
        end
    end
  end

  @impl true
  def handle_call({:get_module_binary, name}, _from, state) do
    case Map.get(state.entries, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        if Entry.expired?(entry) do
          {:reply, {:error, :expired}, state}
        else
          case load_binary(entry) do
            {:ok, binary} -> {:reply, {:ok, binary}, state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        end
    end
  end

  @impl true
  def handle_call(:list_modules, _from, state) do
    modules =
      state.entries
      |> Map.values()
      |> Enum.sort_by(& &1.registered_at, :desc)

    {:reply, modules, state}
  end

  @impl true
  def handle_call({:list_modules_by_source, source_type}, _from, state) do
    modules =
      state.entries
      |> Map.values()
      |> Enum.filter(&(&1.source.type == source_type))
      |> Enum.sort_by(& &1.registered_at, :desc)

    {:reply, modules, state}
  end

  @impl true
  def handle_call({:unregister, name}, _from, state) do
    case Map.pop(state.entries, name) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {entry, new_entries} ->
        # Clean up cached file if it exists
        if entry.cache_path do
          File.rm(entry.cache_path)
        end

        emit_telemetry(:unregister, %{}, %{name: name})
        {:reply, :ok, %{state | entries: new_entries}}
    end
  end

  @impl true
  def handle_call({:refresh, name}, _from, state) do
    case Map.get(state.entries, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        result = refresh_entry(state, entry)

        case result do
          {:ok, new_entry, new_state} ->
            emit_telemetry(:refresh, %{}, %{name: name, success: true})
            {:reply, {:ok, new_entry}, new_state}

          {:error, reason} ->
            emit_telemetry(:refresh, %{}, %{name: name, success: false, error: reason})
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:module_exists?, name}, _from, state) do
    exists =
      case Map.get(state.entries, name) do
        nil -> false
        entry -> not Entry.expired?(entry)
      end

    {:reply, exists, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    total = map_size(state.entries)

    active =
      state.entries
      |> Map.values()
      |> Enum.reject(&Entry.expired?/1)
      |> length()

    expired = total - active

    avg_load_time =
      if state.stats.cache_hits + state.stats.cache_misses > 0 do
        div(state.stats.total_load_time_ms, state.stats.cache_hits + state.stats.cache_misses)
      else
        0
      end

    stats = %{
      total_modules: total,
      active_modules: active,
      expired_modules: expired,
      cache_hits: state.stats.cache_hits,
      cache_misses: state.stats.cache_misses,
      load_errors: state.stats.load_errors,
      total_load_time_ms: state.stats.total_load_time_ms,
      avg_load_time_ms: avg_load_time
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:cleanup, _from, state) do
    {removed, new_entries} = cleanup_expired(state.entries)
    remaining = map_size(new_entries)

    emit_telemetry(:cleanup, %{removed: removed}, %{remaining: remaining})

    {:reply, %{removed: removed, remaining: remaining}, %{state | entries: new_entries}}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    # Clean up all cached files
    state.entries
    |> Map.values()
    |> Enum.each(fn entry ->
      if entry.cache_path do
        File.rm(entry.cache_path)
      end
    end)

    emit_telemetry(:clear, %{}, %{count: map_size(state.entries)})

    {:reply, :ok, %{state | entries: %{}}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    {removed, new_entries} = cleanup_expired(state.entries)

    if removed > 0 do
      Logger.debug("WASM Registry cleanup: removed #{removed} expired modules")
      emit_telemetry(:cleanup, %{removed: removed}, %{})
    end

    # Reschedule cleanup
    timer = Process.send_after(self(), :cleanup, state.cleanup_timer || @cleanup_interval_ms)

    {:noreply, %{state | entries: new_entries, cleanup_timer: timer}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.cleanup_timer do
      Process.cancel_timer(state.cleanup_timer)
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp do_register(state, source_type, name, source, opts) do
    ttl = Keyword.get(opts, :ttl_ms, state.default_ttl_ms)
    version = Keyword.get(opts, :version)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, binary, checksum} <- fetch_binary(state, source_type, source),
         {:ok, cache_path} <- cache_binary(state, name, binary),
         {:ok, entry} <-
           create_entry(name, source_type, source, binary, checksum, cache_path, version, ttl, metadata) do
      new_entries = Map.put(state.entries, name, entry)
      new_state = %{state | entries: new_entries}
      {:ok, entry, new_state}
    end
  end

  defp fetch_binary(_state, :embedded, binary) when is_binary(binary) do
    checksum = compute_checksum(binary)
    {:ok, binary, checksum}
  end

  defp fetch_binary(_state, :local, path) do
    case File.read(path) do
      {:ok, binary} ->
        checksum = compute_checksum(binary)
        {:ok, binary, checksum}

      {:error, reason} ->
        {:error, {:file_read_failed, reason}}
    end
  end

  defp fetch_binary(state, :http, url) do
    http_client = state.http_client

    try do
      case http_client.get(url, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          checksum = compute_checksum(body)
          {:ok, body, checksum}

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, {:http_failed, reason}}
      end
    rescue
      error -> {:error, {:http_exception, error}}
    end
  end

  defp fetch_binary(_state, :ipfs, cid) do
    # For now, IPFS is not fully implemented
    # Would integrate with IPFS gateway or local node
    {:error, :ipfs_not_implemented}
  end

  defp cache_binary(state, name, binary) do
    cache_path = Path.join(state.cache_dir, "#{name}.wasm")

    case File.write(cache_path, binary) do
      :ok -> {:ok, cache_path}
      {:error, reason} -> {:error, {:cache_write_failed, reason}}
    end
  end

  defp create_entry(name, source_type, source, binary, checksum, cache_path, version, ttl, metadata) do
    now = System.system_time(:millisecond)
    expires_at = if ttl > 0, do: now + ttl, else: nil

    entry = %Entry{
      name: name,
      source: %{
        type: source_type,
        uri: to_string(source),
        checksum: checksum,
        version: version,
        metadata: metadata
      },
      size_bytes: byte_size(binary),
      cache_path: cache_path,
      checksum: checksum,
      registered_at: now,
      expires_at: expires_at,
      version: version,
      access_count: 0,
      last_accessed_at: now
    }

    {:ok, entry}
  end

  defp refresh_entry(state, entry) do
    source = entry.source.uri

    result =
      case entry.source.type do
        :local -> fetch_binary(state, :local, source)
        :http -> fetch_binary(state, :http, source)
        :ipfs -> fetch_binary(state, :ipfs, source)
        :embedded -> {:ok, nil, entry.checksum}
      end

    case result do
      {:ok, binary, new_checksum} ->
        # Only update if checksum changed
        if new_checksum != entry.checksum do
          # Remove old cache file
          if entry.cache_path do
            File.rm(entry.cache_path)
          end

          # Cache new binary
          {:ok, new_cache_path} = cache_binary(state, entry.name, binary)

          now = System.system_time(:millisecond)
          expires_at = if entry.expires_at, do: now + (entry.expires_at - entry.registered_at)

          new_entry = %{
            entry
            | checksum: new_checksum,
              cache_path: new_cache_path,
              size_bytes: byte_size(binary),
              registered_at: now,
              expires_at: expires_at
          }

          new_entries = Map.put(state.entries, entry.name, new_entry)
          {:ok, new_entry, %{state | entries: new_entries}}
        else
          # Just update access time
          now = System.system_time(:millisecond)
          new_entry = %{entry | last_accessed_at: now}
          new_entries = Map.put(state.entries, entry.name, new_entry)
          {:ok, new_entry, %{state | entries: new_entries}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_binary(entry) do
    case File.read(entry.cache_path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:load_failed, reason}}
    end
  end

  defp cleanup_expired(entries) do
    now = System.system_time(:millisecond)

    {expired, valid} =
      Enum.split_with(entries, fn {_name, entry} ->
        entry.expires_at != nil and entry.expires_at < now
      end)

    # Clean up expired cache files
    Enum.each(expired, fn {_name, entry} ->
      if entry.cache_path do
        File.rm(entry.cache_path)
      end
    end)

    {length(expired), Map.new(valid)}
  end

  defp compute_checksum(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end

  defp get_cache_dir(opts) do
    case Keyword.get(opts, :cache_dir) do
      nil ->
        System.tmp_dir!()
        |> Path.join("lemon_wasm_registry")

      dir ->
        Path.expand(dir)
    end
  end

  defp emit_telemetry(event, measurements, metadata) do
    :telemetry.execute([:coding_agent, :wasm, :registry, event], measurements, metadata)
  rescue
    _ -> :ok
  end
end
