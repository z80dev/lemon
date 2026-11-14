defmodule LemonCore.ProcessGroup do
  @moduledoc """
  Birth-bound local process-group ownership. An empty observation proves exit only
  for a complete captured witness; missing, recycled or lost ownership is unknown.
  This observes local groups, not escaped sessions, containers or remote work.

  Separately, `signal_group/2`, `signal_pids/2` and `terminate/2` are unverified
  helpers for a group the caller itself just created as the leader of its own
  process group (an Erlang Port child, whose group id is its OS pid): they signal
  the whole group (SIGTERM, bounded grace, SIGKILL) with no birth witness, so
  they must run promptly around the leader's exit, never against a stored id.
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

  def signal_workload_group(identity, signal, root_exited \\ false) do
    signal_workload_group(identity, signal, root_exited, fn _observed -> :ok end)
  end

  @doc """
  Revalidate ownership, then persist the final observed witness before signalling.

  `before_signal` must return `:ok` only after its durability barrier succeeds.
  Any other return, exception or exit refuses the signal.
  """
  def signal_workload_group(identity, signal, root_exited, before_signal)
      when signal in [:sigterm, :sigkill] and is_function(before_signal, 1) do
    case workload_group_status(identity, root_exited) do
      {:alive, %{pgid: pgid} = observed} ->
        result =
          with :ok <- before_signal.(observed), do: signal_process_group(pgid, signal)

        case result do
          :ok -> {:ok, observed}
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

  @default_grace_ms 500
  @poll_ms 20
  @kill_attempts 50

  @doc """
  Signals every member of the local process group `pgid`, without ownership
  verification. Returns `:ok` when the signal reached at least one member,
  `:gone` when the group is empty, and `:error` when no `kill` binary exists.
  `signal` is `:sigterm`, `:sigkill`, or `:probe` (signal 0: liveness only).

  Use this only for a group Lemon itself just created as the leader of its own
  process group (for example an Erlang Port child, which `erl_child_setup`
  starts as a session/group leader, so its group id is its OS pid). Group ids
  are not recycled while any member lives; an unverified signal to an
  already-empty group could hit a recycled id, so callers must signal promptly
  after the leader's exit rather than long after. Ids `<= 1` are refused.
  """
  @spec signal_group(pos_integer(), :sigterm | :sigkill | :probe) :: :ok | :gone | :error
  def signal_group(pgid, signal)
      when is_integer(pgid) and pgid > 1 and signal in [:sigterm, :sigkill, :probe],
      do: run_kill(signal, ["-#{pgid}"])

  def signal_group(_pgid, _signal), do: :gone

  @doc """
  Signals individual OS pids (those that deliberately left the group). Pids
  `<= 1` are dropped. Returns like `signal_group/2`.
  """
  @spec signal_pids([integer()], :sigterm | :sigkill) :: :ok | :gone | :error
  def signal_pids(pids, signal) when is_list(pids) and signal in [:sigterm, :sigkill] do
    case for(pid <- pids, is_integer(pid) and pid > 1, do: Integer.to_string(pid)) do
      [] -> :gone
      targets -> run_kill(signal, targets)
    end
  end

  @doc """
  Terminates a group this process owns: SIGTERM to `-pgid`, poll up to
  `:grace_ms` (default #{@default_grace_ms}) for the group to empty, then SIGKILL
  the group, repeating until it is empty or the bounded attempts run out. The
  group is signalled as a whole, so descendants reparented to init after their
  parent exited (and anything forked during the grace) are still members.
  Returns `:ok` once the group is empty and `:alive` if members survived SIGKILL.
  """
  @spec terminate(pos_integer(), keyword()) :: :ok | :alive | :error
  def terminate(pgid, opts \\ []) when is_integer(pgid) do
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)

    case signal_group(pgid, :sigterm) do
      :gone ->
        :ok

      :error ->
        :error

      :ok ->
        deadline = System.monotonic_time(:millisecond) + grace_ms
        if wait_gone(pgid, deadline), do: :ok, else: kill_until_gone(pgid, @kill_attempts)
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
    case Enum.find(["/bin/kill", "/usr/bin/kill"], &File.regular?/1) do
      nil ->
        :error

      executable ->
        number = if signal == :sigterm, do: "-15", else: "-9"

        {_output, _status} =
          System.cmd(executable, [number, "--", "-#{pgid}"], stderr_to_stdout: true)

        :ok
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
