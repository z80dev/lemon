defmodule LemonCore.ProcessGroup do
  @moduledoc """
  Birth-bound local process-group ownership. An empty observation proves exit only
  for a complete captured witness; missing, recycled or lost ownership is unknown.
  This observes local groups, not escaped sessions, containers or remote work.

  `terminate/2` is the sole termination entry point. A captured identity revalidates
  birth witnesses before signalling; a fresh Port group id can be terminated
  immediately without a stored witness. Observations happen at launch, root exit,
  explicit reconciliation and termination, never on a healthy-process timer.

  VM-killed cleanup remains an explicit limitation: neither erlexec nor MuonTrap
  is adopted. Both introduce another native owner/runtime dependency; neither
  justifies replacing the gated native launcher and durable birth-bound ledger
  without platform crash tests. Boot reconciliation preserves unknown outcomes
  rather than replaying commands or signalling recycled PIDs.

  Termination telemetry uses `[:lemon, :process_group, :start | :stop | :failure]`.
  Start measurements contain `count: 1`; terminal measurements also include
  native monotonic `duration`. Metadata contains only `scope` (`:group` or
  `:process`) and, on terminal events, `outcome`: `:terminated` or `:signaled`
  for stop, `:alive` or `:unobservable` for failure. Process-scoped TERM success
  acknowledges signalling only, not confirmed exit. No process identities,
  commands, paths, output, environment or raw errors are emitted.
  """

  def valid_identity?(%{
        pgid: pgid,
        root_pid: pgid,
        root_birth: birth,
        members: members,
        ownership_lost: false
      })
      when is_integer(pgid) and pgid > 1 and is_binary(birth) and byte_size(birth) > 0 and
             is_map(members) do
    map_size(members) > 0 and (not Map.has_key?(members, pgid) or members[pgid] == birth) and
      Enum.all?(members, fn {pid, member_birth} ->
        is_integer(pid) and pid > 1 and is_binary(member_birth) and byte_size(member_birth) > 0
      end)
  end

  def valid_identity?(_identity), do: false

  def capture_workload_group(os_pid) when is_integer(os_pid) and os_pid > 1 do
    with {:ok, rows} <- process_group_rows(),
         %{pgid: ^os_pid, birth: birth} <- Enum.find(rows, &(&1.pid == os_pid)) do
      {:ok,
       %{
         pgid: os_pid,
         root_pid: os_pid,
         root_birth: birth,
         members: rows |> Enum.filter(&(&1.pgid == os_pid)) |> group_members(),
         ownership_lost: false
       }}
    else
      _ -> {:error, :workload_unobservable}
    end
  end

  def capture_workload_group(_os_pid), do: {:error, :workload_unobservable}

  def workload_group_status(identity, root_exited \\ false) do
    with true <- valid_identity?(identity) and is_boolean(root_exited),
         {:ok, rows} <- process_group_rows() do
      observed_status(identity, root_exited, rows)
    else
      _ -> {:unknown, identity}
    end
  end

  @doc false
  def workload_group_statuses(identities) when map_size(identities) == 0, do: %{}

  def workload_group_statuses(identities) do
    rows = process_group_rows()

    Map.new(identities, fn {id, identity} ->
      status =
        with true <- valid_identity?(identity),
             {:ok, rows} <- rows do
          observed_status(identity, false, rows)
        else
          _ -> {:unknown, identity}
        end

      {id, status}
    end)
  end

  defp observed_status(%{pgid: pgid, root_pid: root_pid} = identity, root_exited, rows) do
    root = Enum.find(rows, &(&1.pid == root_pid))
    live = Enum.filter(rows, &(&1.pgid == pgid and not String.starts_with?(&1.status, "Z")))

    cond do
      root && not String.starts_with?(root.status, "Z") &&
          (root_exited || root.birth != identity.root_birth || root.pgid != pgid) ->
        {:unknown, %{identity | ownership_lost: true}}

      live == [] ->
        :terminated

      (root && root.birth == identity.root_birth) ||
          Enum.any?(live, &(Map.get(identity.members, &1.pid) == &1.birth)) ->
        {:alive, %{identity | members: group_members(live)}}

      true ->
        {:unknown, identity}
    end
  end

  @default_grace_ms 500
  @poll_ms 20
  @kill_attempts 50

  defp signal_group(pgid, signal)
       when is_integer(pgid) and pgid > 1 and signal in [:sigterm, :sigkill, :probe],
       do: run_kill(signal, ["-#{pgid}"])

  defp signal_group(_pgid, _signal), do: :gone

  @doc """
  Terminates a group this process owns: SIGTERM to `-pgid`, poll up to
  `:grace_ms` (default #{@default_grace_ms}) for the group to empty, then SIGKILL
  the group, repeating until it is empty or the bounded attempts run out. The
  group is signalled as a whole, so descendants reparented to init after their
  parent exited (and anything forked during the grace) are still members.
  Returns `:ok` once the group is empty and `:alive` if members survived SIGKILL.

  With a captured identity, validates birth witnesses before each signal and
  returns `{:terminated, identity}` or `{:error, :workload_unobservable, identity}`.
  `:root_exited` carries the observed Port exit; `:before_signal` is a durability
  barrier that must return `:ok`. `:signal` may be `:sigkill` to skip grace.

  Service-manager callers that already verified a single daemon's identity may
  use `scope: :process`: this sends TERM only, without escalation or a group
  signal. The caller retains its existing service shutdown wait. `:command`
  injects that caller's command adapter (executable and argv to `{output, status}`).
  """
  def terminate(group, opts \\ []) do
    started = System.monotonic_time()
    metadata = %{scope: if(Keyword.get(opts, :scope) == :process, do: :process, else: :group)}
    LemonCore.Telemetry.emit([:lemon, :process_group, :start], %{count: 1}, metadata)
    result = do_terminate(group, opts)

    outcome =
      case result do
        :ok -> if metadata.scope == :process, do: :signaled, else: :terminated
        {:terminated, _} -> :terminated
        :alive -> :alive
        _ -> :unobservable
      end

    event = if outcome in [:terminated, :signaled], do: :stop, else: :failure

    LemonCore.Telemetry.emit(
      [:lemon, :process_group, event],
      %{count: 1, duration: System.monotonic_time() - started},
      Map.put(metadata, :outcome, outcome)
    )

    result
  end

  defp do_terminate(pid, opts) when is_integer(pid) and pid > 1 do
    if Keyword.get(opts, :scope, :group) == :process do
      command =
        Keyword.get(opts, :command, fn executable, args ->
          System.cmd(executable, args, stderr_to_stdout: true)
        end)

      case command.("/bin/kill", ["-TERM", Integer.to_string(pid)]) do
        {_output, 0} -> :ok
        _ -> :error
      end
    else
      terminate_group(pid, opts)
    end
  end

  defp do_terminate(identity, opts) when is_map(identity) do
    root_exited = Keyword.get(opts, :root_exited, false)
    before_signal = Keyword.get(opts, :before_signal, fn _observed -> :ok end)
    signal = Keyword.get(opts, :signal, :sigterm)

    case workload_group_status(identity, root_exited) do
      {:alive, observed} ->
        with :ok <- before_signal.(observed),
             :ok <- signal_process_group(observed.pgid, signal) do
          if signal == :sigterm do
            deadline =
              System.monotonic_time(:millisecond) +
                Keyword.get(opts, :grace_ms, @default_grace_ms)

            if not wait_gone(observed.pgid, deadline) do
              do_terminate(observed, Keyword.put(opts, :signal, :sigkill))
            else
              {:terminated, observed}
            end
          else
            await_owned_exit(observed, root_exited, @kill_attempts)
          end
        else
          _ -> {:error, :workload_unobservable, observed}
        end

      :terminated ->
        {:terminated, identity}

      {:unknown, observed} ->
        {:error, :workload_unobservable, observed}
    end
  catch
    _, _ -> {:error, :workload_unobservable, identity}
  end

  defp do_terminate(identity, _opts), do: {:error, :workload_unobservable, identity}

  defp terminate_group(pgid, opts) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)
    signal = Keyword.get(opts, :signal, :sigterm)

    case signal_group(pgid, signal) do
      :gone ->
        :ok

      :error ->
        :error

      :ok ->
        deadline = System.monotonic_time(:millisecond) + grace_ms
        if wait_gone(pgid, deadline), do: :ok, else: kill_until_gone(pgid, @kill_attempts)
    end
  end

  defp await_owned_exit(identity, root_exited, attempts) do
    case workload_group_status(identity, root_exited) do
      :terminated ->
        {:terminated, identity}

      {:alive, observed} when attempts > 0 ->
        Process.sleep(@poll_ms)
        await_owned_exit(observed, root_exited, attempts - 1)

      {_, observed} ->
        {:error, :workload_unobservable, observed}
    end
  end

  defp wait_gone(pgid, deadline) do
    cond do
      signal_group(pgid, :probe) != :ok ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        wait_gone(pgid, deadline)
    end
  end

  defp kill_until_gone(_pgid, 0), do: :alive

  defp kill_until_gone(pgid, attempts) do
    case signal_group(pgid, :sigkill) do
      :ok ->
        Process.sleep(@poll_ms)
        if signal_group(pgid, :probe) == :ok, do: kill_until_gone(pgid, attempts - 1), else: :ok

      :gone ->
        :ok

      :error ->
        :error
    end
  end

  defp run_kill(signal, targets) do
    case Enum.find(["/bin/kill", "/usr/bin/kill"], &File.regular?/1) do
      nil ->
        :error

      executable ->
        number =
          case signal do
            :probe -> "-0"
            :sigterm -> "-15"
            :sigkill -> "-9"
          end

        case System.cmd(executable, [number, "--" | targets], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {_output, _status} -> :gone
        end
    end
  rescue
    _ -> :error
  end

  # Signals the whole verified group through an OS-owned absolute `kill`, with
  # a fixed argv and no shell. A group that exits between the check and the
  # signal is still reconciled by the caller; a missing binary cannot signal.
  defp signal_process_group(pgid, signal) do
    case run_kill(signal, ["-#{pgid}"]) do
      :error -> :error
      _ -> :ok
    end
  end

  defp process_group_rows do
    # OS-owned absolute paths, not a command-controlled PATH executable.
    case Enum.find(["/bin/ps", "/usr/bin/ps"], &File.regular?/1) do
      nil ->
        {:error, :workload_unobservable}

      executable ->
        case System.cmd(executable, ["-axo", "pid=,pgid=,stat=,lstart="], stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.split("\n", trim: true)
            |> Enum.reduce_while({:ok, []}, fn line, {:ok, rows} ->
              case String.split(String.trim(line), ~r/\s+/, parts: 4) do
                [pid, pgid, status, birth] ->
                  with {pid, ""} <- Integer.parse(pid),
                       {pgid, ""} <- Integer.parse(pgid) do
                    {:cont, {:ok, [%{pid: pid, pgid: pgid, status: status, birth: birth} | rows]}}
                  else
                    _ -> {:halt, {:error, :workload_unobservable}}
                  end

                _ ->
                  {:halt, {:error, :workload_unobservable}}
              end
            end)
            |> case do
              {:ok, [_ | _] = rows} -> {:ok, rows}
              _ -> {:error, :workload_unobservable}
            end

          _ ->
            {:error, :workload_unobservable}
        end
    end
  rescue
    _ -> {:error, :workload_unobservable}
  end

  defp group_members(rows), do: Map.new(rows, &{&1.pid, &1.birth})
end
