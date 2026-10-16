defmodule LemonCore.ProcessGroup do
  @moduledoc """
  Birth-bound local process-group ownership. An empty observation proves exit only
  for a complete captured witness; missing, recycled or lost ownership is unknown.
  This observes local groups, not escaped sessions, containers or remote work.
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
