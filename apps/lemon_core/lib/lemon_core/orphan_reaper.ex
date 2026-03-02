defmodule LemonCore.OrphanReaper do
  @moduledoc """
  Periodically scans for orphaned processes in agent workspace directories and kills them.

  When agent sessions (openclaw/kimi) spawn child processes like `vitest` or `node`
  in `~/.lemon/agent/workspace/` directories, those children become orphaned if the
  parent dies or times out. Orphaned processes get reparented to launchd (PPID=1) and
  spin indefinitely.

  This GenServer runs every 60 seconds and:
  1. Finds processes with PPID=1 and >= 1% CPU
  2. Checks if their CWD is inside `~/.lemon/agent/workspace/`
  3. Sends SIGTERM to newly discovered orphans
  4. Sends SIGKILL on the next sweep to orphans that survived SIGTERM

  Only runs on macOS (`:unix, :darwin`).
  """

  use GenServer

  require Logger

  @sweep_interval_ms 60_000
  @cpu_threshold 1.0

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    case :os.type() do
      {:unix, :darwin} ->
        schedule_sweep()
        {:ok, %{sigtermed: MapSet.new()}}

      _ ->
        Logger.debug("[OrphanReaper] Not macOS, disabling orphan reaper")
        :ignore
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    state = sweep(state)
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Internals ---

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp sweep(state) do
    beam_pid = System.pid() |> String.to_integer()
    workspace_dir = workspace_dir()

    candidates =
      list_orphan_candidates()
      |> Enum.reject(fn %{pid: pid} -> pid == beam_pid end)

    orphan_pids =
      candidates
      |> Enum.filter(fn %{pid: pid} -> process_in_workspace?(pid, workspace_dir) end)
      |> Enum.map(& &1.pid)
      |> MapSet.new()

    # Processes that were SIGTERMed last sweep and are still alive get SIGKILLed
    still_alive = MapSet.intersection(state.sigtermed, orphan_pids)

    for pid <- still_alive do
      Logger.warning("[OrphanReaper] SIGKILL orphan pid=#{pid} (survived SIGTERM)")
      System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
    end

    # New orphans that weren't previously SIGTERMed get SIGTERM
    new_orphans = MapSet.difference(orphan_pids, state.sigtermed)

    for pid <- new_orphans do
      Logger.warning("[OrphanReaper] SIGTERM orphan pid=#{pid}")
      System.cmd("kill", ["-15", to_string(pid)], stderr_to_stdout: true)
    end

    if MapSet.size(new_orphans) == 0 and MapSet.size(still_alive) == 0 do
      Logger.debug("[OrphanReaper] Sweep complete, no orphans found")
    end

    # Track the ones we just SIGTERMed (minus the ones we SIGKILLed, they're gone)
    %{state | sigtermed: new_orphans}
  end

  @doc false
  def workspace_dir do
    Path.join([System.user_home!(), ".lemon", "agent", "workspace"])
  end

  defp list_orphan_candidates do
    case System.cmd("ps", ["-eo", "pid,ppid,pcpu,comm"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        # Skip header line
        |> Enum.drop(1)
        |> Enum.flat_map(&parse_ps_line/1)
        |> Enum.filter(fn %{ppid: ppid, cpu: cpu} ->
          ppid == 1 and cpu >= @cpu_threshold
        end)

      {err, _code} ->
        Logger.error("[OrphanReaper] ps command failed: #{String.trim(err)}")
        []
    end
  end

  defp parse_ps_line(line) do
    case String.split(String.trim(line), ~r/\s+/, parts: 4) do
      [pid_str, ppid_str, cpu_str, _comm] ->
        with {pid, ""} <- Integer.parse(pid_str),
             {ppid, ""} <- Integer.parse(ppid_str),
             {cpu, _} <- Float.parse(cpu_str) do
          [%{pid: pid, ppid: ppid, cpu: cpu}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp process_in_workspace?(pid, workspace_dir) do
    case System.cmd("lsof", ["-p", to_string(pid), "-Fn"],
           stderr_to_stdout: true,
           env: [{"LANG", "C"}]
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.any?(fn
          "n" <> path -> String.starts_with?(path, workspace_dir)
          _ -> false
        end)

      _ ->
        false
    end
  end
end
