defmodule LemonCore.ConfigCache do
  @moduledoc """
  ETS-backed cache for merged Lemon configuration.

  Goals:
  - Avoid hot-path TOML disk reads/parsing.
  - Provide consistent semantics: cached reads by default + explicit reload.
  - Detect on-disk changes via periodic (TTL) file fingerprint checks (mtime/size).
  """

  use GenServer

  @table :lemon_core_config_cache
  @defaults_key {__MODULE__, :defaults}

  @default_mtime_check_interval_ms 1_000
  @default_call_timeout_ms 5_000

  # Row format: {key, base_config, fingerprint, loaded_at_ms, checked_at_ms}
  # Fingerprint is a list of {path, {mtime, size} | :missing}.

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
    interval = Keyword.get(opts, :mtime_check_interval_ms) || defaults().mtime_check_interval_ms

    case :ets.lookup(@table, key) do
      [] ->
        GenServer.call(__MODULE__, {:load, cwd}, call_timeout(opts))

      [{^key, base, fingerprint, _loaded_at, checked_at}] ->
        if now - checked_at < interval do
          base
        else
          new_fp = fingerprint(paths)

          if new_fp == fingerprint do
            _ = :ets.update_element(@table, key, {5, now})
            base
          else
            GenServer.call(__MODULE__, {:reload, cwd}, call_timeout(opts))
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
  def reload(cwd \\ nil, opts \\ []) do
    ensure_available!()
    GenServer.call(__MODULE__, {:reload, cwd, opts}, call_timeout(opts))
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

  @impl true
  def init(opts) do
    _ =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    defaults = %{
      mtime_check_interval_ms:
        Keyword.get(opts, :mtime_check_interval_ms, @default_mtime_check_interval_ms),
      call_timeout_ms: Keyword.get(opts, :call_timeout_ms, @default_call_timeout_ms)
    }

    :persistent_term.put(@defaults_key, defaults)

    {:ok, %{defaults: defaults}}
  end

  @impl true
  def handle_call({:load, cwd}, _from, state) do
    paths = config_paths(cwd)
    key = cache_key(paths)
    now = now_ms()

    case :ets.lookup(@table, key) do
      [{^key, base, _fp, _loaded_at, _checked_at}] ->
        {:reply, base, state}

      [] ->
        {base, fp} = load_base(cwd, paths)
        _ = :ets.insert(@table, {key, base, fp, now, now})
        {:reply, base, state}
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
    {base, fp} = load_base(cwd, paths)
    _ = :ets.insert(@table, {key, base, fp, now, now})

    # Optionally validate and log warnings
    if Keyword.get(opts, :validate, false) do
      validate_config(base)
    end

    {:reply, base, state}
  end

  defp load_base(cwd, paths) do
    base = LemonCore.Config.load_base_from_disk(cwd)
    fp = fingerprint(paths)
    {base, fp}
  end

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

  defp ensure_available! do
    if available?() do
      :ok
    else
      raise LemonCore.ConfigCacheError,
        message: "LemonCore.ConfigCache is not available (application not started)"
    end
  end

  defp defaults do
    case :persistent_term.get(@defaults_key, nil) do
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
