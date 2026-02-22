defmodule LemonCore.ConfigReloader do
  @moduledoc """
  Central orchestrator for runtime config reload.

  Detects config changes from files, environment, and secrets, reloads the
  canonical config, computes a redacted diff, and broadcasts update events
  on `LemonCore.Bus`.

  ## Reload Pipeline

  1. Acquire reload lock (serialize concurrent reloads)
  2. Compute current source digests
  3. Determine changed sources (skip if unchanged and not forced)
  4. If env source changed, reload `.env`
  5. Reload canonical config via `LemonCore.Config.reload/2`
  6. Compute redacted diff vs previous snapshot
  7. Persist new snapshot + digests
  8. Broadcast `%LemonCore.Event{type: :config_reloaded}` on topic `"system"`
  9. On failure, keep last good snapshot and emit `:config_reload_failed`

  ## Telemetry

  - `[:lemon, :config, :reload, :start]`
  - `[:lemon, :config, :reload, :stop]`
  - `[:lemon, :config, :reload, :exception]`
  """

  use GenServer

  require Logger

  alias LemonCore.ConfigReloader.Digest

  @type source :: :files | :env | :secrets
  @type reload_result :: %{
          reload_id: String.t(),
          changed_sources: [source()],
          changed_paths: [String.t()],
          applied_at_ms: non_neg_integer(),
          actions: [map()]
        }

  @default_sources [:files, :env, :secrets]
  @redact_patterns ~w(token secret api_key password)

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the ConfigReloader GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger a config reload.

  ## Options

  - `:sources` - list of sources to check (default: `[:files, :env, :secrets]`)
  - `:force` - bypass digest comparison and force reload (default: `false`)
  - `:reason` - why the reload was triggered (`:watcher`, `:poll`, `:manual`, `:secrets_event`)
  - `:cwd` - override the working directory for config lookup
  - `:validate` - run config validation (default: `true`)
  """
  @spec reload(keyword()) :: {:ok, reload_result()} | {:error, term()}
  def reload(opts \\ []) do
    GenServer.call(__MODULE__, {:reload, opts}, 30_000)
  end

  @doc """
  Trigger a reload asynchronously. Fire-and-forget.
  """
  @spec reload_async(keyword()) :: :ok
  def reload_async(opts \\ []) do
    GenServer.cast(__MODULE__, {:reload, opts})
  end

  @doc """
  Return current reloader status.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Return the list of file paths being watched.
  """
  @spec watch_paths() :: [String.t()]
  def watch_paths do
    GenServer.call(__MODULE__, :watch_paths)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd)

    state = %{
      cwd: cwd,
      last_snapshot: nil,
      digests: %{},
      last_reload_at: nil,
      last_error: nil,
      reload_count: 0,
      lock: false
    }

    # Take an initial snapshot so we have a baseline for diffing
    {:ok, take_initial_snapshot(state)}
  end

  @impl true
  def handle_call({:reload, opts}, _from, state) do
    if state.lock do
      {:reply, {:error, :reload_in_progress}, state}
    else
      state = %{state | lock: true}
      {result, state} = do_reload(opts, state)
      state = %{state | lock: false}
      {:reply, result, state}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{
      last_reload_at: state.last_reload_at,
      last_error: state.last_error,
      reload_count: state.reload_count,
      cwd: state.cwd,
      sources: Map.keys(state.digests),
      has_snapshot: state.last_snapshot != nil
    }

    {:reply, status, state}
  end

  def handle_call(:watch_paths, _from, state) do
    paths = config_file_paths(state.cwd)
    {:reply, paths, state}
  end

  @impl true
  def handle_cast({:reload, opts}, state) do
    if state.lock do
      Logger.debug("[ConfigReloader] Skipping async reload — another reload is in progress")
      {:noreply, state}
    else
      state = %{state | lock: true}
      {_result, state} = do_reload(opts, state)
      state = %{state | lock: false}
      {:noreply, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Core reload logic
  # ---------------------------------------------------------------------------

  defp do_reload(opts, state) do
    reload_id = LemonCore.Id.uuid()
    sources = Keyword.get(opts, :sources, @default_sources)
    force = Keyword.get(opts, :force, false)
    reason = Keyword.get(opts, :reason, :manual)
    cwd = Keyword.get(opts, :cwd, state.cwd)
    validate = Keyword.get(opts, :validate, true)

    telemetry_meta = %{reload_id: reload_id, reason: reason, sources: sources}

    :telemetry.execute(
      [:lemon, :config, :reload, :start],
      %{system_time: System.system_time()},
      telemetry_meta
    )

    start_mono = System.monotonic_time(:millisecond)

    try do
      # 1. Compute current digests
      new_digests = compute_digests(sources, cwd)

      # 2. Determine changed sources
      {changed_sources, merged_digests} =
        if force do
          {sources, Map.merge(state.digests, new_digests)}
        else
          Digest.compare(state.digests, Map.merge(state.digests, new_digests))
        end

      # Filter to requested sources
      changed_sources = Enum.filter(changed_sources, &(&1 in sources))

      if changed_sources == [] and not force do
        Logger.debug("[ConfigReloader] No changes detected (reason=#{reason})")

        result = %{
          reload_id: reload_id,
          changed_sources: [],
          changed_paths: [],
          applied_at_ms: System.system_time(:millisecond),
          actions: []
        }

        duration_ms = System.monotonic_time(:millisecond) - start_mono

        :telemetry.execute(
          [:lemon, :config, :reload, :stop],
          %{duration: duration_ms * 1_000_000, duration_ms: duration_ms},
          Map.put(telemetry_meta, :changed_count, 0)
        )

        {{:ok, result}, %{state | digests: merged_digests}}
      else
        # 3. If env changed, reload .env
        if :env in changed_sources do
          dotenv_dir = dotenv_dir(cwd)
          LemonCore.Dotenv.load_and_log(dotenv_dir, override: true)
        end

        # 4. Reload canonical config
        new_config = LemonCore.Config.reload(cwd, validate: validate)

        # 5. Compute redacted diff
        old_map = if state.last_snapshot, do: config_to_comparable(state.last_snapshot), else: %{}
        new_map = config_to_comparable(new_config)
        diff = compute_redacted_diff(old_map, new_map)

        changed_paths =
          diff
          |> Enum.map(fn {path, _change} -> path end)
          |> Enum.sort()

        now = System.system_time(:millisecond)

        # 6. Build result
        result = %{
          reload_id: reload_id,
          changed_sources: changed_sources,
          changed_paths: changed_paths,
          applied_at_ms: now,
          actions: []
        }

        # 7. Broadcast event
        event = LemonCore.Event.new(:config_reloaded, %{
          reload_id: reload_id,
          reason: reason,
          changed_sources: changed_sources,
          changed_paths: changed_paths,
          diff: diff
        })

        LemonCore.Bus.broadcast("system", event)

        Logger.info(
          "[ConfigReloader] Reload complete (reason=#{reason}, " <>
            "changed_sources=#{inspect(changed_sources)}, " <>
            "changed_paths=#{length(changed_paths)})"
        )

        duration_ms = System.monotonic_time(:millisecond) - start_mono

        :telemetry.execute(
          [:lemon, :config, :reload, :stop],
          %{duration: duration_ms * 1_000_000, duration_ms: duration_ms},
          Map.merge(telemetry_meta, %{
            changed_count: length(changed_sources),
            actions_count: 0
          })
        )

        new_state = %{
          state
          | last_snapshot: new_config,
            digests: merged_digests,
            last_reload_at: now,
            last_error: nil,
            reload_count: state.reload_count + 1
        }

        {{:ok, result}, new_state}
      end
    rescue
      e ->
        duration_ms = System.monotonic_time(:millisecond) - start_mono

        Logger.warning(
          "[ConfigReloader] Reload failed (reason=#{reason}): #{Exception.message(e)}"
        )

        :telemetry.execute(
          [:lemon, :config, :reload, :exception],
          %{duration: duration_ms * 1_000_000, duration_ms: duration_ms},
          Map.merge(telemetry_meta, %{
            kind: :error,
            reason: e,
            stacktrace: __STACKTRACE__
          })
        )

        # Broadcast failure event
        fail_event = LemonCore.Event.new(:config_reload_failed, %{
          reload_id: reload_id,
          reason: reason,
          error: Exception.message(e)
        })

        LemonCore.Bus.broadcast("system", fail_event)

        new_state = %{state | last_error: Exception.message(e)}
        {{:error, {:reload_failed, Exception.message(e)}}, new_state}
    end
  end

  # ---------------------------------------------------------------------------
  # Digest computation
  # ---------------------------------------------------------------------------

  defp compute_digests(sources, cwd) do
    Enum.reduce(sources, %{}, fn source, acc ->
      digest = compute_source_digest(source, cwd)
      Map.put(acc, source, digest)
    end)
  end

  defp compute_source_digest(:files, cwd) do
    paths = config_file_paths(cwd)
    Digest.files_digest(paths)
  end

  defp compute_source_digest(:env, cwd) do
    dotenv_path = LemonCore.Dotenv.path_for(dotenv_dir(cwd))
    Digest.env_digest(dotenv_path)
  end

  defp compute_source_digest(:secrets, _cwd) do
    case LemonCore.Secrets.list() do
      {:ok, metadata_list} -> Digest.secrets_digest(metadata_list)
      _ -> Digest.secrets_digest([])
    end
  end

  # ---------------------------------------------------------------------------
  # Diff computation
  # ---------------------------------------------------------------------------

  @doc false
  @spec compute_redacted_diff(map(), map()) :: [{String.t(), map()}]
  def compute_redacted_diff(old_map, new_map) do
    old_flat = flatten_map(old_map)
    new_flat = flatten_map(new_map)

    all_keys = MapSet.union(MapSet.new(Map.keys(old_flat)), MapSet.new(Map.keys(new_flat)))

    all_keys
    |> Enum.reduce([], fn key, acc ->
      old_val = Map.get(old_flat, key)
      new_val = Map.get(new_flat, key)

      cond do
        old_val == new_val ->
          acc

        is_nil(old_val) ->
          [{key, %{action: :added, value: redact_value(key, new_val)}} | acc]

        is_nil(new_val) ->
          [{key, %{action: :removed, value: redact_value(key, old_val)}} | acc]

        true ->
          [{key, %{action: :changed, from: redact_value(key, old_val), to: redact_value(key, new_val)}} | acc]
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp take_initial_snapshot(state) do
    try do
      config = LemonCore.Config.load(state.cwd)
      digests = compute_digests(@default_sources, state.cwd)

      %{state | last_snapshot: config, digests: digests}
    rescue
      _ -> state
    end
  end

  defp config_file_paths(cwd) do
    global = LemonCore.Config.global_path() |> Path.expand()

    project =
      if is_binary(cwd) and cwd != "" do
        [LemonCore.Config.project_path(cwd) |> Path.expand()]
      else
        []
      end

    [global | project]
  end

  defp dotenv_dir(cwd) do
    System.get_env("LEMON_DOTENV_DIR") || cwd
  end

  defp config_to_comparable(%LemonCore.Config{} = config) do
    LemonCore.Config.to_map(config)
  end

  defp config_to_comparable(other) when is_map(other), do: other
  defp config_to_comparable(_), do: %{}

  @doc false
  @spec redact_value(String.t(), term()) :: term()
  def redact_value(key, value) do
    key_lower = String.downcase(key)

    if Enum.any?(@redact_patterns, &String.contains?(key_lower, &1)) do
      "[REDACTED]"
    else
      value
    end
  end

  defp flatten_map(map, prefix \\ "") do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      full_key = if prefix == "", do: to_string(key), else: "#{prefix}.#{key}"

      if is_map(value) and not is_struct(value) and map_size(value) > 0 do
        Map.merge(acc, flatten_map(value, full_key))
      else
        Map.put(acc, full_key, value)
      end
    end)
  end
end
