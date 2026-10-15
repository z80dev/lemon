defmodule CodingAgent.Tools.ReadFormatCommand do
  @moduledoc false

  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

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
         {:ok, port} <- open(executable, args) do
      try do
        collect(
          port,
          [],
          0,
          signal,
          System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 30_000),
          Keyword.get(opts, :max_bytes, 32 * 1024 * 1024)
        )
      after
        close(port)
      end
    end
  end

  defp open(executable, args) do
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

  # The command can exit between any liveness check and the close, and closing
  # an already-closed port raises; either way the port is gone.
  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp collect(port, chunks, size, signal, deadline, max_bytes) do
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
                max_bytes
              )
            end

          {^port, {:exit_status, 0}} ->
            {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

          {^port, {:exit_status, status}} ->
            output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

            {:error,
             "Document backend exited with status #{status}: #{String.slice(output, 0, 2000)}"}
        after
          50 -> collect(port, chunks, size, signal, deadline, max_bytes)
        end
      end
    end
  end
end
