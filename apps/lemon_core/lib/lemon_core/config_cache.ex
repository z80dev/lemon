defmodule LemonCore.ConfigCache.CollisionError do
  @moduledoc """
  Raised when a `LemonCore.ConfigCache` ETS table name is already taken by
  another process — mirrors `LemonCore.Store.ReadCache.CollisionError`.
  """

  defexception [:message]
end

defmodule LemonCore.ConfigCache do
  @moduledoc """
  ETS-backed cache for merged Lemon configuration.

  Goals:
  - Avoid hot-path TOML disk reads/parsing.
  - Provide consistent semantics: cached reads by default + explicit reload.
  - Detect on-disk changes via periodic (TTL) file fingerprint checks (mtime/size).
  - Serve the last good config when an implicit reload fails.

  ## Failed implicit reloads

  When a TTL check finds changed files and the reload fails (invalid TOML or a
  validation error), `get/2` keeps serving the previously cached config. The
  failure is recorded on the entry as `%{error_class, fingerprint, failed_at}`
  (see `last_error/1`), logged once and reported through the
  `[:lemon, :config_cache, :reload_failed]` telemetry event. No further load is
  attempted until the files' fingerprint changes again. Only a first load with no
  previous entry raises: there is no last good config to serve.

  `reload/2` is the explicit path and still raises.

  Every disk load emits `[:lemon, :config_cache, :load]`.

  The cache is registered as `LemonCore.ConfigCache`.
  Options come from `start_link/1` first, falling back to
  `Application.get_env(:lemon_core, LemonCore.ConfigCache)`.
  """

  use GenServer

  alias LemonCore.ConfigCache.CollisionError

  @table :lemon_core_config_cache

  @default_mtime_check_interval_ms 1_000
  @default_call_timeout_ms 5_000

  # Row format: {key, base_config, fingerprint, loaded_at_ms, checked_at_ms, failure}
  # Fingerprint is a list of {path, {mtime, size} | :missing}.
  # Failure is nil or the last failed implicit reload (see `last_error/1`).

  require Logger

  @type failure :: %{
          error_class: module(),
          fingerprint: [{String.t(), term()}],
          failed_at: integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns true if the cache is running and its ETS table exists.
  """
  @spec available?() :: boolean()
  def available? do
    is_pid(Process.whereis(__MODULE__)) and :ets.whereis(@table) != :undefined
  end

  @doc """
  Get the cached *base* config for `cwd` (merged global + project TOML, no env/overrides).

  Uses a TTL to avoid frequent stat calls; when the TTL elapses it will check file
  fingerprints (mtime/size) and reload if they changed.

  Cache keys are based on the resolved config file paths (global + project). This is
  important for tests, where `HOME` may change between cases.
  """
  @spec get(String.t() | nil, keyword()) :: LemonCore.Config.t()
  def get(cwd \\ nil, opts \\ []) do
    ensure_available!()
    paths = config_paths(cwd)
    key = cache_key(paths)
    now = now_ms()

    interval =
      Keyword.get(opts, :mtime_check_interval_ms) || defaults().mtime_check_interval_ms

    case :ets.lookup(@table, key) do
      [] ->
        __MODULE__
        |> GenServer.call({:load, cwd}, call_timeout(opts))
        |> reply_or_raise()

      [{^key, base, fingerprint, _loaded_at, checked_at, failure}] ->
        if now - checked_at < interval do
          base
        else
          new_fp = fingerprint(paths)

          if new_fp == fingerprint or failed_fingerprint?(failure, new_fp) do
            _ = :ets.update_element(@table, key, {5, now})
            base
          else
            __MODULE__
            |> GenServer.call({:refresh, cwd}, call_timeout(opts))
            |> reply_or_raise()
          end
        end
    end
  end

  @doc """
  The last failed implicit reload for `cwd`, or `nil` when the cached entry is
  current (or nothing is cached).

  The failure carries the exception module (`error_class`), the file
  fingerprint that failed and the monotonic `failed_at` time in milliseconds.
  """
  @spec last_error(String.t() | nil) :: failure() | nil
  def last_error(cwd \\ nil) do
    if available?() do
      key = cache_key(config_paths(cwd))

      case :ets.lookup(@table, key) do
        [{^key, _base, _fp, _loaded_at, _checked_at, failure}] -> failure
        [] -> nil
      end
    end
  end

  @doc """
  Force reload the cached *base* config for `cwd` from disk.

  Configuration is validated before replacing the cache entry. Invalid settings
  raise `LemonCore.Config.ValidationError` and leave the previous entry intact.

  ## Examples

      LemonCore.ConfigCache.reload()
  """
  @spec reload(String.t() | nil, keyword()) :: LemonCore.Config.t()
  def reload(cwd \\ nil, opts \\ []) do
    ensure_available!()

    __MODULE__
    |> GenServer.call({:reload, cwd}, call_timeout(opts))
    |> reply_or_raise()
  end

  @doc """
  Drop the cached entry for `cwd`.
  """
  @spec invalidate(String.t() | nil) :: :ok
  def invalidate(cwd \\ nil) do
    if available?() do
      _ = :ets.delete(@table, cache_key(config_paths(cwd)))
    end

    :ok
  end

  @doc """
  Drop every cached entry in the default cache instance.

  A no-op when the cache is not running. Used when config files or environment
  variables change at runtime, so entries resolved under the old rules are not
  served.

  Routed through the cache server rather than deleting from the caller's
  process, so a clear queues behind in-flight loads: a load that read the
  world (e.g. the resolver set) before the clear cannot insert its stale row
  after the table was wiped and have it served for the node's lifetime.
  """
  @spec clear() :: :ok
  def clear do
    if available?() do
      _ = GenServer.call(__MODULE__, :clear, call_timeout([]))
    end

    :ok
  catch
    # The server stopped between the availability check and the call; its ETS
    # table died with it, so there is nothing stale left to serve.
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  @impl true
  def init(opts) do
    opts =
      :lemon_core
      |> Application.get_env(__MODULE__, [])
      |> Keyword.merge(Keyword.take(opts, [:mtime_check_interval_ms, :call_timeout_ms]))

    _ = new_table!()

    defaults = %{
      mtime_check_interval_ms:
        Keyword.get(opts, :mtime_check_interval_ms, @default_mtime_check_interval_ms),
      call_timeout_ms: Keyword.get(opts, :call_timeout_ms, @default_call_timeout_ms)
    }

    :persistent_term.put({__MODULE__, :defaults}, defaults)

    {:ok, %{table: @table}}
  end

  # A live table under our name belongs to someone else — two caches sharing one
  # table would serve each other's parsed config. Raising `CollisionError` says
  # so; a bare `:ets.new/2` badarg here would not.
  defp new_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      tid ->
        raise CollisionError,
          message:
            "ConfigCache ETS table #{inspect(@table)} already exists and is " <>
              "owned by #{inspect(:ets.info(tid, :owner))}."
    end
  end

  @impl true
  def handle_call({:load, cwd}, _from, state) do
    paths = config_paths(cwd)
    key = cache_key(paths)
    now = now_ms()

    case :ets.lookup(state.table, key) do
      [{^key, base, _fp, _loaded_at, _checked_at, _failure}] ->
        {:reply, base, state}

      [] ->
        case safe_load_base(cwd, paths) do
          {:ok, base, fp} ->
            _ = :ets.insert(state.table, {key, base, fp, now, now, nil})
            {:reply, base, state}

          {:error, exception, stacktrace} ->
            {:reply, {:error, exception, stacktrace}, state}
        end
    end
  end

  def handle_call(:clear, _from, state) do
    _ = :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call({:reload, cwd}, _from, state) do
    paths = config_paths(cwd)
    key = cache_key(paths)
    now = now_ms()

    case safe_load_base(cwd, paths) do
      {:ok, base, fp} ->
        _ = :ets.insert(state.table, {key, base, fp, now, now, nil})

        {:reply, base, state}

      {:error, exception, stacktrace} ->
        {:reply, {:error, exception, stacktrace}, state}
    end
  end

  # Implicit reload from `get/2`. Callers queued behind one refresh re-check the
  # fingerprint here, so a burst of reads after an edit loads the files once.
  def handle_call({:refresh, cwd}, _from, state) do
    paths = config_paths(cwd)
    key = cache_key(paths)
    now = now_ms()

    case :ets.lookup(state.table, key) do
      # The entry was dropped (invalidate/clear) meanwhile: no last good config
      # to serve, so this is a first load and a failure raises in the caller.
      [] ->
        case safe_load_base(cwd, paths) do
          {:ok, base, fp} ->
            _ = :ets.insert(state.table, {key, base, fp, now, now, nil})
            {:reply, base, state}

          error ->
            {:reply, error, state}
        end

      [{^key, base, fingerprint, _loaded_at, _checked_at, failure}] ->
        current_fp = fingerprint(paths)

        if current_fp == fingerprint or failed_fingerprint?(failure, current_fp) do
          _ = :ets.update_element(state.table, key, {5, now})
          {:reply, base, state}
        else
          {:reply, refresh_entry(state, cwd, paths, key, base, now), state}
        end
    end
  end

  defp refresh_entry(state, cwd, paths, key, last_good, now) do
    case safe_load_base(cwd, paths) do
      {:ok, base, fp} ->
        _ = :ets.insert(state.table, {key, base, fp, now, now, nil})
        base

      {:error, exception, _stacktrace} ->
        failure = %{
          error_class: exception.__struct__,
          fingerprint: fingerprint(paths),
          failed_at: now
        }

        _ = :ets.update_element(state.table, key, [{5, now}, {6, failure}])
        report_failure(failure)
        last_good
    end
  end

  # Reported once per failing fingerprint: later reads short-circuit on it.
  # Only the exception class is logged; its message may quote config values.
  defp report_failure(failure) do
    Logger.error(
      "Config reload failed (#{inspect(failure.error_class)}); serving the last good config. " <>
        "Run `lemon config validate` for details."
    )

    :telemetry.execute([:lemon, :config_cache, :reload_failed], %{count: 1}, %{
      error_class: failure.error_class
    })
  end

  defp failed_fingerprint?(%{fingerprint: fp}, fp), do: true
  defp failed_fingerprint?(_failure, _fp), do: false

  defp load_base(cwd, paths) do
    # Stat before parsing: a file written during the load then fails the next
    # fingerprint check and is re-read, instead of its new fingerprint being
    # cached beside content parsed from the previous (or a partial) file.
    fp = fingerprint(paths)
    :telemetry.execute([:lemon, :config_cache, :load], %{count: 1}, %{})
    base = LemonCore.Config.load_base_from_disk(cwd)
    {base, fp}
  end

  defp safe_load_base(cwd, paths) do
    {base, fp} = load_base(cwd, paths)
    {:ok, base, fp}
  rescue
    exception ->
      {:error, exception, __STACKTRACE__}
  end

  defp reply_or_raise({:error, exception, stacktrace}), do: reraise(exception, stacktrace)
  defp reply_or_raise(reply), do: reply

  defp config_paths(cwd) do
    global = LemonCore.Config.global_path() |> Path.expand()

    # Same project-layer selection as `Config.Modular`: none for an assistant home.
    project =
      if is_binary(cwd) and cwd != "", do: LemonCore.Config.Modular.project_layer_path(cwd)

    if project, do: [global, Path.expand(project)], else: [global]
  end

  defp fingerprint(paths) when is_list(paths) do
    Enum.map(paths, fn path ->
      {path, file_fingerprint(path)}
    end)
  end

  defp file_fingerprint(path) do
    case File.stat(path) do
      {:ok, stat} -> {stat.mtime, stat.size}
      {:error, _} -> :missing
    end
  end

  defp cache_key(paths) when is_list(paths), do: {:paths, paths}

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp ensure_available! do
    if available?() do
      :ok
    else
      raise LemonCore.ConfigCacheError,
        message:
          "Lemon config cache is not running. Run `lemon doctor` to check application startup."
    end
  end

  defp defaults do
    case :persistent_term.get({__MODULE__, :defaults}, nil) do
      nil ->
        %{
          mtime_check_interval_ms: @default_mtime_check_interval_ms,
          call_timeout_ms: @default_call_timeout_ms
        }

      map ->
        map
    end
  end

  defp call_timeout(opts) do
    Keyword.get(opts, :call_timeout_ms) || defaults().call_timeout_ms
  end
end
