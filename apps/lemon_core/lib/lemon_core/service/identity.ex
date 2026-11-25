defmodule LemonCore.Service.Identity do
  @moduledoc """
  Same-user process identity checks. Signals are bound to PID and start time.

  This OS process's own identity and effective uid never change, so
  `boot_check/0` (run by `LemonCore.Application`) publishes them once in
  `:persistent_term`; lock acquisition then forks nothing. On Linux they come
  from `/proc/self`, with `ps`/`id` as the fallback. A failed capture is never
  published, and outside a booted application each read captures afresh.
  Other processes are still inspected with `ps`, which the runtime image ships
  (`procps`).
  """

  require Logger

  alias LemonCore.ProcessGroup
  alias LemonCore.Service.{Command, Role, Unit}

  @self_key {__MODULE__, :self}
  @uid_key {__MODULE__, :uid}
  @at_clktck 17

  @doc """
  Publishes this OS process's identity and uid once at boot, and logs an error
  when either is unavailable or `ps` (needed to verify other lock holders) is
  missing.
  """
  @spec boot_check() ::
          :ok | {:error, :process_identity_unverified | :uid_unavailable | :ps_unavailable}
  def boot_check do
    with {:ok, uid} <- current_uid(),
         :ok <- :persistent_term.put(@uid_key, uid),
         {:ok, identity} <- self_identity(),
         :ok <- :persistent_term.put(@self_key, identity),
         exe when is_binary(exe) <- System.find_executable("ps") do
      :ok
    else
      nil -> boot_failed(:ps_unavailable)
      {:error, reason} -> boot_failed(reason)
    end
  end

  defp boot_failed(reason) do
    Logger.error(
      "Cross-process locks are unavailable (#{reason}): install procps so `ps` is on PATH"
    )

    {:error, reason}
  end

  @doc "Returns this OS process's real identity, published at boot or captured now."
  @spec self_identity() :: {:ok, map()} | {:error, :process_identity_unverified}
  def self_identity do
    case :persistent_term.get(@self_key, nil) do
      %{} = identity -> {:ok, identity}
      nil -> capture_self([])
    end
  end

  @doc "Captures this OS process's identity without the cache: `/proc` on Linux, else `ps`."
  @spec capture_self(keyword()) :: {:ok, map()} | {:error, :process_identity_unverified}
  def capture_self(opts) do
    pid = String.to_integer(System.pid())

    with true <- linux?(opts),
         {:ok, identity} <- proc_identity(pid, Keyword.get(opts, :proc_root, "/proc")) do
      {:ok, identity}
    else
      _ -> capture(pid, opts)
    end
  end

  @doc "Returns this OS process's effective uid, published at boot or read now."
  @spec current_uid() :: {:ok, non_neg_integer()} | {:error, :uid_unavailable}
  def current_uid do
    case :persistent_term.get(@uid_key, nil) do
      uid when is_integer(uid) -> {:ok, uid}
      nil -> read_uid()
    end
  end

  def uid(opts) do
    Keyword.get_lazy(opts, :uid, fn ->
      case current_uid() do
        {:ok, uid} -> uid
        {:error, _} -> "unknown"
      end
    end)
    |> to_string()
  end

  defp read_uid do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, effective] <- Regex.run(~r/^Uid:\s+\d+\s+(\d+)/m, status) do
      {:ok, String.to_integer(effective)}
    else
      _ -> id_uid()
    end
  end

  defp id_uid do
    with {output, 0} <- System.cmd("id", ["-u"], stderr_to_stdout: true),
         {uid, ""} when uid >= 0 <- Integer.parse(String.trim(output)) do
      {:ok, uid}
    else
      _ -> {:error, :uid_unavailable}
    end
  rescue
    _ -> {:error, :uid_unavailable}
  end

  # Same arithmetic as procps `lstart`: boot time + start ticks / CLK_TCK,
  # truncated to seconds and rendered like ctime(3) in local time.
  defp proc_identity(pid, root) do
    with {:ok, stat} <- File.read(Path.join([root, "self", "stat"])),
         [_, stat_pid, rest] <- Regex.run(~r/\A(\d+) \(.*\) (.*)\z/s, stat),
         ^pid <- String.to_integer(stat_pid),
         {ticks, ""} <- rest |> String.split() |> Enum.at(19, "") |> Integer.parse(),
         {:ok, system} <- File.read(Path.join(root, "stat")),
         [_, btime] <- Regex.run(~r/^btime (\d+)$/m, system),
         {:ok, hz} <- clock_ticks(root),
         {:ok, executable} <- File.read_link(Path.join([root, "self", "exe"])) do
      started = String.to_integer(btime) + div(ticks, hz)
      {:ok, %{pid: pid, started_at: ctime(started), executable: executable}}
    else
      _ -> :error
    end
  end

  defp clock_ticks(root) do
    with {:ok, auxv} <- File.read(Path.join([root, "self", "auxv"])) do
      find_clktck(auxv)
    end
  end

  defp find_clktck(<<@at_clktck::native-64, hz::native-64, _::binary>>) when hz > 0,
    do: {:ok, hz}

  defp find_clktck(<<0::native-64, _::native-64, _::binary>>), do: :error
  defp find_clktck(<<_::native-64, _::native-64, rest::binary>>), do: find_clktck(rest)
  defp find_clktck(_), do: :error

  @days ~w(Mon Tue Wed Thu Fri Sat Sun)
  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  defp ctime(seconds) do
    {{year, month, day} = date, {hour, minute, second}} =
      :calendar.system_time_to_local_time(seconds, :second)

    time =
      [hour, minute, second]
      |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))

    Enum.join(
      [
        Enum.at(@days, :calendar.day_of_the_week(date) - 1),
        Enum.at(@months, month - 1),
        day,
        time,
        year
      ],
      " "
    )
  end

  defp linux?(opts), do: Keyword.get(opts, :os, :os.type()) in [:linux, {:unix, :linux}]

  def capture(pid, opts) when is_integer(pid) and pid > 1 do
    with {output, 0} <-
           Command.run("ps", ["-p", to_string(pid), "-o", "uid=,lstart=,comm="], opts),
         [_, uid, started, executable] <-
           Regex.run(~r/^\s*(\d+)\s+(\S+\s+\S+\s+\d+\s+[\d:]+\s+\d{4})\s+(.+?)\s*$/s, output),
         true <- uid == uid(opts) do
      {:ok,
       %{
         pid: pid,
         started_at: normalize_time(started),
         executable: executable_path(pid, executable, opts)
       }}
    else
      _ -> {:error, :process_identity_unverified}
    end
  end

  def capture(_, _), do: {:error, :process_identity_unverified}

  def same?(identity, opts) do
    case capture(identity.pid, opts) do
      {:ok, current} -> current == identity
      _ -> false
    end
  end

  def gone?(identity, opts) do
    case Command.run("ps", ["-p", to_string(identity.pid), "-o", "lstart="], opts) do
      {started, 0} ->
        normalize_time(started) != identity.started_at and String.trim(started) != ""

      {output, 1} ->
        String.trim(output) == ""

      _ ->
        false
    end
  end

  def terminate(identity, opts) do
    if same?(identity, opts) do
      result =
        ProcessGroup.terminate(identity.pid,
          scope: :process,
          command: fn executable, args -> Command.run(executable, args, opts) end
        )

      case result do
        :ok ->
          deadline =
            System.monotonic_time(:millisecond) + Keyword.get(opts, :stop_timeout, 15_000)

          wait_gone(identity, deadline, opts)

        _ ->
          {:error, :service_command_failed}
      end
    else
      {:error, :process_identity_changed}
    end
  end

  defp wait_gone(identity, deadline, opts) do
    cond do
      gone?(identity, opts) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :stop_timeout}

      true ->
        Process.sleep(100)
        wait_gone(identity, deadline, opts)
    end
  end

  def listeners(port, opts) do
    if Keyword.get(opts, :os, :os.type()) in [:linux, {:unix, :linux}] do
      case linux_listeners(port, opts) do
        :unavailable -> lsof_listeners(port, opts)
        listeners -> listeners
      end
    else
      lsof_listeners(port, opts)
    end
  end

  defp lsof_listeners(port, opts) do
    case Command.run("lsof", ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN", "-Fp"], opts) do
      {output, status} when status in [0, 1] ->
        Regex.scan(~r/^p(\d+)$/m, output)
        |> Enum.map(fn [_, pid] -> String.to_integer(pid) end)
        |> Enum.uniq()

      _ ->
        :unknown
    end
  end

  defp linux_listeners(port, opts) do
    proc_root = Keyword.get(opts, :proc_root, "/proc")

    with {:ok, inodes} <- listener_inodes(proc_root, port),
         {:ok, pids} <- listener_pids(proc_root, inodes) do
      pids
    else
      {:error, :socket_owner_unverified} -> :unknown
      _ -> :unavailable
    end
  end

  defp listener_inodes(proc_root, port) do
    hex_port =
      port
      |> Integer.to_string(16)
      |> String.upcase()
      |> String.pad_leading(4, "0")

    with {:ok, ipv4} <- File.read(Path.join([proc_root, "net", "tcp"])),
         {:ok, ipv6} <- optional_file(Path.join([proc_root, "net", "tcp6"])) do
      inodes =
        (String.split(ipv4, "\n") ++ String.split(ipv6, "\n"))
        |> Enum.reduce(MapSet.new(), fn line, acc ->
          case String.split(line) do
            [_, local, _, "0A", _, _, _, _, _, inode | _] ->
              if String.ends_with?(local, ":" <> hex_port),
                do: MapSet.put(acc, inode),
                else: acc

            _ ->
              acc
          end
        end)

      {:ok, inodes}
    end
  end

  defp optional_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:ok, ""}
      error -> error
    end
  end

  defp listener_pids(proc_root, inodes) do
    if MapSet.size(inodes) == 0 do
      {:ok, []}
    else
      with {:ok, entries} <- File.ls(proc_root) do
        {found, pids} =
          Enum.reduce(entries, {MapSet.new(), MapSet.new()}, fn entry, acc ->
            case Integer.parse(entry) do
              {pid, ""} when pid > 0 -> pid_listeners(proc_root, entry, pid, inodes, acc)
              _ -> acc
            end
          end)

        if MapSet.equal?(found, inodes),
          do: {:ok, pids |> MapSet.to_list() |> Enum.sort()},
          else: {:error, :socket_owner_unverified}
      end
    end
  end

  defp pid_listeners(proc_root, entry, pid, inodes, {found, pids}) do
    directory = Path.join([proc_root, entry, "fd"])

    case File.ls(directory) do
      {:ok, descriptors} ->
        Enum.reduce(descriptors, {found, pids}, fn descriptor, {seen, owners} = acc ->
          case File.read_link(Path.join(directory, descriptor)) do
            {:ok, "socket:[" <> rest} ->
              inode = String.trim_trailing(rest, "]")

              if MapSet.member?(inodes, inode),
                do: {MapSet.put(seen, inode), MapSet.put(owners, pid)},
                else: acc

            _ ->
              acc
          end
        end)

      _ ->
        {found, pids}
    end
  end

  def backend_program?(identity, bot, opts) do
    identity.executable == bot or
      String.starts_with?(
        identity.executable,
        Path.join(Role.home(opts), ".lemon/lemon_bot/versions") <> "/"
      )
  end

  def legacy_workers(name, opts) do
    case Command.run("ps", ["-axo", "pid=,uid=,lstart=,command="], opts) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+[\d:]+\s+\d{4})\s+(.+)$/, line) do
            [_, pid, owner, started, command] ->
              with true <- owner == uid(opts),
                   {:ok, words} <- Unit.split_command(command, :process),
                   true <- word_sequence?(words, ["node", "join", "--name", name]),
                   {:ok, identity} <- capture(String.to_integer(pid), opts),
                   true <- identity.started_at == normalize_time(started),
                   true <- beam_program?(identity.executable, opts) do
                [identity]
              else
                _ -> []
              end

            _ ->
              []
          end
        end)

      _ ->
        {:error, :process_scan_failed}
    end
  end

  defp word_sequence?(words, sequence),
    do: Enum.chunk_every(words, length(sequence), 1, :discard) |> Enum.any?(&(&1 == sequence))

  defp beam_program?(program, opts) do
    roots = [Path.join(Role.home(opts), ".lemon/versions"), to_string(:code.root_dir())]

    String.ends_with?(program, "/bin/beam.smp") and
      Enum.any?(roots, &String.starts_with?(program, &1 <> "/"))
  end

  defp executable_path(pid, fallback, opts) do
    if Keyword.get(opts, :os, :os.type()) in [:linux, {:unix, :linux}] do
      case Command.run("readlink", ["/proc/#{pid}/exe"], opts) do
        {path, 0} -> String.trim(path)
        _ -> String.trim(fallback)
      end
    else
      String.trim(fallback)
    end
  end

  def read_json(path) do
    with {:ok, %{type: :regular, size: size, mode: mode}} when size <= 65_536 <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, body} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      {:ok, map}
    else
      {:error, :enoent} -> {:error, :not_found}
      _ -> {:error, :invalid_record}
    end
  end

  def normalize_time(value) when is_binary(value),
    do: value |> String.trim() |> String.replace(~r/\s+/, " ")

  def normalize_time(_), do: nil
end
