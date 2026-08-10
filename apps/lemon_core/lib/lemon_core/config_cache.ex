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

  ## Instances

  The cache is named (default `LemonCore.ConfigCache`) and every public function
  takes an optional leading server argument. A second instance gets its own ETS
  table, derived from its name, so several caches can coexist in one node.
  Options come from `start_link/1` first, falling back to
  `Application.get_env(:lemon_core, name)`.
  """

  use GenServer

  alias LemonCore.ConfigCache.CollisionError

  @table :lemon_core_config_cache

  @default_mtime_check_interval_ms 1_000
  @default_call_timeout_ms 5_000

  @typedoc "A running config cache, addressed by its registered name."
  @type server :: atom()

  # Row format: {key, base_config, fingerprint, loaded_at_ms, checked_at_ms}
  # Fingerprint is a list of {path, {mtime, size} | :missing}.

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    unless is_atom(name) and not is_nil(name) do
      raise ArgumentError, "LemonCore.ConfigCache :name must be an atom, got: #{inspect(name)}"
    end

    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Returns true if the cache is running and its ETS table exists.
  """
  @spec available?(server()) :: boolean()
  def available?(server \\ __MODULE__) do
    is_pid(whereis(server)) and :ets.whereis(table_for(server)) != :undefined
  end

  @doc """
  Return the ETS table name backing a cache instance.
  """
  @spec table_for(server()) :: atom()
  def table_for(__MODULE__), do: @table

  def table_for(server) when is_atom(server) and not is_nil(server) do
    suffix =
      case Atom.to_string(server) do
        "Elixir." <> rest -> rest |> String.replace(".", "_") |> Macro.underscore()
        other -> other
      end

    :"lemon_core_config_cache_#{suffix}"
  end

  defp whereis(server) when is_atom(server), do: Process.whereis(server)

  @doc """
  Get the cached *base* config for `cwd` (merged global + project TOML, no env/overrides).

  Uses a TTL to avoid frequent stat calls; when the TTL elapses it will check file
  fingerprints (mtime/size) and reload if they changed.

  Cache keys are based on the resolved config file paths (global + project). This is
  important for tests, where `HOME` may change between cases.
  """
  @spec get(String.t() | nil, keyword()) :: LemonCore.Config.t()
  def get(cwd \\ nil, opts \\ []), do: get(__MODULE__, cwd, opts)

  @doc """
  Get the cached base config for `cwd` from a specific cache instance.
  """
  @spec get(server(), String.t() | nil, keyword()) :: LemonCore.Config.t()
  def get(server, cwd, opts) do
    ensure_available!(server)

    table = table_for(server)
    paths = config_paths(cwd)
    key = cache_key(paths)
    now = now_ms()

    interval =
      Keyword.get(opts, :mtime_check_interval_ms) || defaults(server).mtime_check_interval_ms

    case :ets.lookup(table, key) do
      [] ->
        server
        |> GenServer.call({:load, cwd}, call_timeout(server, opts))
        |> reply_or_raise()

      [{^key, base, fingerprint, _loaded_at, checked_at}] ->
        if now - checked_at < interval do
          base
        else
          new_fp = fingerprint(paths)

          if new_fp == fingerprint do
            _ = :ets.update_element(table, key, {5, now})
            base
          else
            server
            |> GenServer.call({:reload, cwd}, call_timeout(server, opts))
            |> reply_or_raise()
          end
        end
    end
  end

  @doc """
  Force reload the cached *base* config for `cwd` from disk.

  ## Options

    * `:validate` - Whether to validate the config and log warnings on validation errors
      (default: false to maintain backward compatibility)

  ## Examples

      # Reload without validation
      LemonCore.ConfigCache.reload()

      # Reload with validation warnings
      LemonCore.ConfigCache.reload(validate: true)
  """
  @spec reload(String.t() | nil, keyword()) :: LemonCore.Config.t()
  def reload(cwd \\ nil, opts \\ []), do: reload(__MODULE__, cwd, opts)

  @doc """
  Force reload the cached base config for `cwd` in a specific cache instance.
  """
  @spec reload(server(), String.t() | nil, keyword()) :: LemonCore.Config.t()
  def reload(server, cwd, opts) do
    ensure_available!(server)

    server
    |> GenServer.call({:reload, cwd, opts}, call_timeout(server, opts))
    |> reply_or_raise()
  end

  @doc """
  Drop the cached entry for `cwd`.
  """
  @spec invalidate(String.t() | nil) :: :ok
  def invalidate(cwd \\ nil), do: invalidate(__MODULE__, cwd)

  @doc """
  Drop the cached entry for `cwd` in a specific cache instance.
  """
  @spec invalidate(server(), String.t() | nil) :: :ok
  def invalidate(server, cwd) do
    if available?(server) do
      _ = :ets.delete(table_for(server), cache_key(config_paths(cwd)))
    end

    :ok
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    opts =
      :lemon_core
      |> Application.get_env(name, [])
      |> Keyword.merge(Keyword.take(opts, [:mtime_check_interval_ms, :call_timeout_ms]))

    _ = new_table!(name)

    defaults = %{
      mtime_check_interval_ms:
        Keyword.get(opts, :mtime_check_interval_ms, @default_mtime_check_interval_ms),
      call_timeout_ms: Keyword.get(opts, :call_timeout_ms, @default_call_timeout_ms)
    }

    :persistent_term.put(defaults_key(name), defaults)

    {:ok, %{name: name, table: table_for(name), defaults: defaults}}
  end

  # A live table under our name belongs to someone else — two caches sharing one
  # table would serve each other's parsed config. Raising `CollisionError` says
  # so; a bare `:ets.new/2` badarg here would not.
  defp new_table!(name) do
    table = table_for(name)

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :named_table,
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      tid ->
        raise CollisionError,
          message:
            "ConfigCache ETS table #{inspect(table)} for #{inspect(name)} already exists and is " <>
              "owned by #{inspect(:ets.info(tid, :owner))}. Give the cache a distinct :name so " <>
              "it gets its own table."
    end
  end

  @impl true
  def handle_call({:load, cwd}, _from, state) do
    paths = config_paths(cwd)
    key = cache_key(paths)
    now = now_ms()

    case :ets.lookup(state.table, key) do
      [{^key, base, _fp, _loaded_at, _checked_at}] ->
        {:reply, base, state}

      [] ->
        case safe_load_base(cwd, paths) do
          {:ok, base, fp} ->
            _ = :ets.insert(state.table, {key, base, fp, now, now})
            {:reply, base, state}

          {:error, exception, stacktrace} ->
            {:reply, {:error, exception, stacktrace}, state}
        end
    end
  end

  def handle_call({:reload, cwd}, from, state) do
    # Backward compatibility: call without opts
    handle_call({:reload, cwd, []}, from, state)
  end

  def handle_call({:reload, cwd, opts}, _from, state) do
    paths = config_paths(cwd)
    key = cache_key(paths)
    now = now_ms()

    case safe_load_base(cwd, paths) do
      {:ok, base, fp} ->
        _ = :ets.insert(state.table, {key, base, fp, now, now})

        # Optionally validate and log warnings
        if Keyword.get(opts, :validate, false) do
          validate_config(base)
        end

        {:reply, base, state}

      {:error, exception, stacktrace} ->
        {:reply, {:error, exception, stacktrace}, state}
    end
  end

  defp load_base(cwd, paths) do
    base = LemonCore.Config.load_base_from_disk(cwd)
    fp = fingerprint(paths)
    {base, fp}
  end

  defp safe_load_base(cwd, paths) do
    try do
      {base, fp} = load_base(cwd, paths)
      {:ok, base, fp}
    rescue
      exception ->
        {:error, exception, __STACKTRACE__}
    end
  end

  defp reply_or_raise({:error, exception, stacktrace}), do: reraise(exception, stacktrace)
  defp reply_or_raise(reply), do: reply

  defp validate_config(base_config) do
    # Validate the legacy config struct directly
    # The Validator module can handle both modular and legacy configs
    case LemonCore.Config.Validator.validate(base_config) do
      :ok ->
        :ok

      {:error, errors} ->
        require Logger

        Logger.warning("""
        Configuration validation warnings after reload:
        #{Enum.map_join(errors, "\n", &"  - #{&1}")}
        """)
    end
  end

  defp config_paths(cwd) do
    global = LemonCore.Config.global_path() |> Path.expand()

    if is_binary(cwd) and cwd != "" do
      project = LemonCore.Config.project_path(cwd) |> Path.expand()
      [global, project]
    else
      [global]
    end
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

  defp ensure_available!(server) do
    if available?(server) do
      :ok
    else
      raise LemonCore.ConfigCacheError,
        message: "#{inspect(server)} is not available (application not started)"
    end
  end

  defp defaults_key(server), do: {__MODULE__, server, :defaults}

  defp defaults(server) do
    case :persistent_term.get(defaults_key(server), nil) do
      nil ->
        %{
          mtime_check_interval_ms: @default_mtime_check_interval_ms,
          call_timeout_ms: @default_call_timeout_ms
        }

      map ->
        map
    end
  end

  defp call_timeout(server, opts) do
    Keyword.get(opts, :call_timeout_ms) || defaults(server).call_timeout_ms
  end
end
