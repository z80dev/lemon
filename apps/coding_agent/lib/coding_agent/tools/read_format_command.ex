defmodule CodingAgent.Tools.ReadFormatCommand do
  @moduledoc false

  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  alias CodingAgent.BashExecutor

  # PATH is operator configuration, but relative entries and workspace binaries
  # are not an implicit grant to execute project code for a fetch-only tool.
  def system_executable(name, cwd) do
    case canonical_path(Path.expand(cwd)) do
      {:ok, real_cwd} ->
        ancestors = Enum.uniq(ancestors(Path.expand(cwd)) ++ ancestors(real_cwd))

        roots =
          [Path.expand(cwd), real_cwd] ++
            Enum.map(ancestors, &Path.join(&1, ".lemon")) ++
            Enum.filter(ancestors, &File.exists?(Path.join(&1, ".git")))

        roots =
          Enum.uniq(
            roots ++
              Enum.flat_map(roots, fn root ->
                case canonical_path(root) do
                  {:ok, real} -> [real]
                  {:error, _} -> []
                end
              end)
          )

        (System.get_env("PATH") || "")
        |> String.split(if(match?({:win32, _}, :os.type()), do: ";", else: ":"))
        |> Enum.filter(&(Path.type(&1) == :absolute))
        |> Enum.find_value(fn directory ->
          executable = Path.join(directory, name)

          with {:ok, real} <- canonical_path(executable),
               false <-
                 Enum.any?(roots, &(inside?(Path.expand(executable), &1) or inside?(real, &1))),
               found when is_binary(found) <- System.find_executable(executable) do
            found
          else
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  # Explicit constructor selection grants trust, but still require a resolvable
  # executable before probing. Keep the selected path for virtualenv semantics.
  def operator_executable(nil, _cwd), do: nil

  def operator_executable(path, cwd) when is_binary(path) do
    executable = Path.expand(path, cwd)

    case canonical_path(executable) do
      {:ok, _real} -> System.find_executable(executable)
      _ -> nil
    end
  end

  def operator_executable(_path, _cwd), do: nil

  defp inside?(path, root),
    do: path == root or String.starts_with?(path, String.trim_trailing(root, "/") <> "/")

  defp ancestors(path) do
    parent = Path.dirname(path)
    if parent == path, do: [path], else: [path | ancestors(parent)]
  end

  defp canonical_path(path) do
    [root | parts] = Path.split(path)
    resolve_parts(parts, root, 0)
  end

  defp resolve_parts(_, _, hops) when hops > 40, do: {:error, :eloop}
  defp resolve_parts([], resolved, _hops), do: {:ok, resolved}
  defp resolve_parts(["." | rest], resolved, hops), do: resolve_parts(rest, resolved, hops)

  defp resolve_parts([".." | rest], resolved, hops),
    do: resolve_parts(rest, Path.dirname(resolved), hops)

  defp resolve_parts([part | rest], resolved, hops) do
    candidate = Path.join(resolved, part)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        with {:ok, target} <- File.read_link(candidate) do
          if Path.type(target) == :absolute do
            [root | parts] = Path.split(target)
            resolve_parts(parts ++ rest, root, hops + 1)
          else
            resolve_parts(Path.split(target) ++ rest, resolved, hops + 1)
          end
        end

      {:ok, _} ->
        resolve_parts(rest, candidate, hops)

      error ->
        error
    end
  end

  def run(executable, args, signal, opts \\ []) do
    with :ok <- check_abort(signal),
         {:ok, port, guard} <- start_backend(executable, args, opts) do
      try do
        collect(
          port,
          [],
          0,
          signal,
          System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 30_000),
          Keyword.get(opts, :max_bytes, 32 * 1024 * 1024),
          guard.monitor
        )
      after
        release_backend(guard)
      end
    end
  end

  defp start_backend(executable, args, opts) do
    caller = self()
    request = make_ref()

    {owner, monitor} =
      spawn_monitor(fn -> own_backend(caller, request, executable, args, opts) end)

    receive do
      {^request, {:ok, port}} ->
        {:ok, port, %{owner: owner, monitor: monitor}}

      {^request, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        {:error, reason}

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, "Document backend owner exited: #{inspect(reason)}"}
    end
  end

  defp own_backend(caller, request, executable, args, opts) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)

    marker = "\0" <> Base.encode16(:crypto.strong_rand_bytes(24)) <> ":"

    case open(executable, args, marker) do
      {:ok, port} ->
        case guard_backend(port, opts) do
          {:ok, group} ->
            if group, do: Port.command(port, "start\n")
            send(caller, {request, {:ok, port}})

            relay_backend(port, caller, caller_monitor, group, false, marker, "")

          {:error, reason} ->
            send(caller, {request, {:error, reason}})
        end

      {:error, reason} ->
        send(caller, {request, {:error, reason}})
    end
  end

  defp relay_backend(port, caller, caller_monitor, group, root_exited, marker, pending) do
    receive do
      {^port, {:data, bytes}} when not is_nil(group) ->
        pending = relay_output(port, caller, pending <> bytes, marker)
        relay_backend(port, caller, caller_monitor, group, root_exited, marker, pending)

      {^port, {:exit_status, _} = payload} ->
        send(caller, {port, payload})
        relay_backend(port, caller, caller_monitor, group, true, marker, pending)

      {^port, payload} ->
        send(caller, {port, payload})
        relay_backend(port, caller, caller_monitor, group, root_exited, marker, pending)

      {:release, ^caller} ->
        stop_backend(port, group, root_exited)

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        stop_backend(port, group, root_exited)

      {:EXIT, ^port, _reason} ->
        relay_backend(port, caller, caller_monitor, group, root_exited, marker, pending)
    end
  end

  # Only the trusted shell emits this per-invocation completion frame. Retain
  # a possible partial frame while forwarding all backend bytes unchanged.
  defp relay_output(port, caller, bytes, marker) do
    case :binary.split(bytes, marker) do
      [output, status] ->
        send(caller, {port, {:data, output}})

        case :binary.split(status, <<0>>) do
          [status, trailing] ->
            if trailing != "", do: send(caller, {port, {:data, trailing}})
            send(caller, {port, {:exit_status, String.to_integer(status)}})
            ""

          [_partial] ->
            marker <> status
        end

      [output] ->
        size = max(byte_size(output) - byte_size(marker) + 1, 0)
        <<ready::binary-size(^size), pending::binary>> = output
        if ready != "", do: send(caller, {port, {:data, ready}})
        pending
    end
  end

  defp stop_backend(port, group, root_exited) do
    if group, do: BashExecutor.signal_workload_group(group, :sigkill, root_exited)
    close(port)
  end

  defp open(executable, args, marker) do
    # Keep the witnessed leader alive even when the backend forks and exits
    # before the guardian can observe it. Backend stdin remains EOF, as before.
    # Completion travels in a private frame; the leader waits for cleanup.
    {executable, args} =
      if match?({:unix, _}, :os.type()) do
        {"/bin/sh",
         [
           "-c",
           ~S(read -r start || exit 125; marker=$1; shift; "$@" </dev/null; status=$?; printf '\000%s:%s\000' "$marker" "$status"; read -r release),
           "read-backend",
           marker |> String.trim_leading(<<0>>) |> String.trim_trailing(":"),
           executable | args
         ]}
      else
        {executable, args}
      end

    {:ok,
     Port.open({:spawn_executable, executable}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       args: args,
       env: [{~c"PYTHONIOENCODING", ~c"utf-8"}]
     ])}
  rescue
    error -> {:error, "Cannot start document backend: #{Exception.message(error)}"}
  end

  # The guardian owns the port from creation, so caller death cannot close it
  # before the process-group witness is checked and surviving children stopped.
  # On Unix an unwitnessed backend is killed through its still-open port and refused.
  defp guard_backend(port, opts) do
    capture = Keyword.get(opts, :capture_group, &BashExecutor.capture_workload_group/1)

    with {:os_pid, os_pid} <- Port.info(port, :os_pid),
         {:ok, group} <- capture.(os_pid) do
      {:ok, group}
    else
      _ -> unguarded_backend(port, :os.type())
    end
  end

  # No process groups or `ps`; closing the port is the existing contract.
  defp unguarded_backend(_port, {:win32, _}), do: {:ok, nil}

  defp unguarded_backend(port, _unix) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid),
         do: BashExecutor.kill_process_tree(os_pid)

    close(port)

    {:error,
     "Cannot prove the document backend's process group (needs ps); refusing to run a backend that could not be stopped."}
  end

  defp release_backend(guard) do
    send(guard.owner, {:release, self()})

    if Process.alive?(guard.owner) do
      receive do
        {:DOWN, ref, :process, owner, _reason}
        when ref == guard.monitor and owner == guard.owner ->
          :ok
      end
    end

    Process.demonitor(guard.monitor, [:flush])
  end

  # The command can exit between any liveness check and the close, and closing
  # an already-closed port raises; either way the port is gone.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp collect(port, chunks, size, signal, deadline, max_bytes, monitor) do
    with :ok <- check_abort(signal) do
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, "Document backend timed out. Select fewer pages or a smaller document."}
      else
        receive do
          {^port, {:data, bytes}} ->
            if size + byte_size(bytes) > max_bytes do
              {:error,
               "Document backend output exceeds #{max_bytes} bytes. Select fewer pages with page/page_limit."}
            else
              collect(
                port,
                [bytes | chunks],
                size + byte_size(bytes),
                signal,
                deadline,
                max_bytes,
                monitor
              )
            end

          {^port, {:exit_status, 0}} ->
            with :ok <- check_abort(signal),
                 do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

          {^port, {:exit_status, status}} ->
            output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

            {:error,
             "Document backend exited with status #{status}: #{String.slice(output, 0, 2000)}"}

          {:DOWN, ^monitor, :process, _owner, reason} ->
            {:error, "Document backend owner exited: #{inspect(reason)}"}
        after
          50 -> collect(port, chunks, size, signal, deadline, max_bytes, monitor)
        end
      end
    end
  end
end
