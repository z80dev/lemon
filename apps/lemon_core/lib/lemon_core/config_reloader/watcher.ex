defmodule LemonCore.ConfigReloader.Watcher do
  @moduledoc """
  File-system watcher for config reload triggers.

  Uses the `file_system` library (when available) to watch config files for
  changes. Falls back to periodic polling when the native watcher is not
  available or fails to start.

  Watched paths:
  - `~/.lemon/config.toml`
  - `<cwd>/.lemon/config.toml`
  - `.env` (from `LEMON_DOTENV_DIR` or cwd)

  File-system events are debounced (250ms) to avoid redundant reloads from
  editor save sequences.
  """

  use GenServer

  require Logger

  @debounce_ms 250
  @poll_interval_ms 5_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the Watcher GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd)
    debounce_ms = Keyword.get(opts, :debounce_ms, @debounce_ms)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)

    state = %{
      cwd: cwd,
      debounce_ms: debounce_ms,
      poll_interval_ms: poll_interval_ms,
      watcher_pid: nil,
      debounce_ref: nil,
      mode: :polling
    }

    state = try_start_watcher(state)

    # Always schedule poll as fallback
    schedule_poll(state)

    {:ok, state}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    Logger.debug("[ConfigReloader.Watcher] File event: #{path} #{inspect(events)}")
    {:noreply, debounce_reload(state)}
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("[ConfigReloader.Watcher] File watcher stopped, falling back to polling")
    {:noreply, %{state | watcher_pid: nil, mode: :polling}}
  end

  def handle_info(:debounced_reload, state) do
    Logger.debug("[ConfigReloader.Watcher] Triggering debounced reload")
    do_trigger_reload(:watcher)
    {:noreply, %{state | debounce_ref: nil}}
  end

  def handle_info(:poll, state) do
    Logger.debug("[ConfigReloader.Watcher] Poll check")
    do_trigger_reload(:poll)
    schedule_poll(state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.watcher_pid && Process.alive?(state.watcher_pid) do
      GenServer.stop(state.watcher_pid, :normal, 1_000)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp try_start_watcher(state) do
    if Code.ensure_loaded?(FileSystem) do
      dirs = watch_directories(state.cwd)

      case FileSystem.start_link(dirs: dirs) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          Logger.info("[ConfigReloader.Watcher] Native file watcher started for #{inspect(dirs)}")
          %{state | watcher_pid: pid, mode: :native}

        {:error, reason} ->
          Logger.warning(
            "[ConfigReloader.Watcher] Failed to start native watcher: #{inspect(reason)}, using polling"
          )

          state
      end
    else
      Logger.info("[ConfigReloader.Watcher] file_system not available, using polling")
      state
    end
  end

  defp watch_directories(cwd) do
    global_dir = Path.expand("~/.lemon")
    dotenv_dir = System.get_env("LEMON_DOTENV_DIR") || cwd || File.cwd!()

    dirs = [global_dir, Path.expand(dotenv_dir)]

    dirs =
      if is_binary(cwd) and cwd != "" do
        project_dir = Path.join(Path.expand(cwd), ".lemon")
        [project_dir | dirs]
      else
        dirs
      end

    dirs
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  defp debounce_reload(state) do
    if state.debounce_ref do
      Process.cancel_timer(state.debounce_ref)
    end

    ref = Process.send_after(self(), :debounced_reload, state.debounce_ms)
    %{state | debounce_ref: ref}
  end

  defp schedule_poll(state) do
    Process.send_after(self(), :poll, state.poll_interval_ms)
  end

  defp do_trigger_reload(reason) do
    if is_pid(Process.whereis(LemonCore.ConfigReloader)) do
      LemonCore.ConfigReloader.reload_async(reason: reason)
    end
  end
end
