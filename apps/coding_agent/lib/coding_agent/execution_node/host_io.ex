defmodule CodingAgent.ExecutionNode.HostIO do
  @moduledoc """
  Destination-local host, bounded file transfer and write-only secret operations.

  `handle/3` accepts JSON maps and returns JSON maps or safe error atoms. Paths
  resolve relative to `:default_cwd` (home by default), within `:allowed_roots`
  (home by default). Options are worker-owned, never supplied by RPC callers.
  `resolve/2` also serves the worker's shell cwd policy. This is path admission,
  not an OS sandbox against another process concurrently replacing directories.
  """

  alias CodingAgent.ExecutionNode.HostInfo
  alias LemonCore.Secrets

  @max_chunk 1_048_576
  @max_base64 1_398_104
  @list_limit 500
  @methods ~w(node.host.info node.fs.list node.fs.stat node.fs.read node.fs.write node.fs.mkdir node.fs.move node.fs.delete node.secrets.set node.secrets.list node.secrets.delete)

  @spec handle(String.t(), map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def handle(method, args, opts \\ []) do
    result =
      try do
        if method in @methods and is_map(args),
          do: dispatch(method, args, opts),
          else: {:error, :invalid_request}
      rescue
        _ -> {:error, :host_io_failed}
      catch
        :exit, _ -> {:error, :host_io_unavailable}
      end

    # Fixed-cardinality, content-free audit: no paths, names, values or results.
    LemonCore.Telemetry.emit(
      [:coding_agent, :execution_node, :host_io],
      %{count: 1},
      %{method: if(method in @methods, do: method, else: "unknown"), outcome: outcome(result)}
    )

    result
  end

  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def resolve(path, opts \\ []) do
    with :ok <- valid_path(path),
         {:ok, cwd} <- default_cwd(opts),
         {:ok, roots} <- allowed_roots(opts),
         expanded = Path.expand(path, cwd),
         true <- Enum.any?(roots, fn {lexical, root} ->
           inside?(expanded, lexical) or inside?(expanded, root)
         end),
         {:ok, canonical} <- canonical(expanded),
         true <- Enum.any?(roots, fn {_, root} -> inside?(canonical, root) end) do
      {:ok, canonical}
    else
      false -> {:error, :path_not_allowed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch("node.host.info", _args, opts), do: HostInfo.get(opts)

  defp dispatch("node.fs.list", args, opts) do
    with {:ok, path} <- resolve(args["path"], opts),
         {:ok, hidden} <- boolean(args, "showHidden", false),
         {:ok, names} <- File.ls(path) do
      names = Enum.filter(names, &(hidden or not String.starts_with?(&1, ".")))
      entries =
        names
        |> Enum.sort()
        |> Enum.take(@list_limit)
        |> Enum.map(fn name ->
          child = Path.join(path, name)
          case File.lstat(child, time: :posix) do
            {:ok, stat} -> Map.put(stat_view(child, stat), "name", name)
            {:error, reason} -> %{"name" => name, "error" => Atom.to_string(file_error(reason))}
          end
        end)

      {:ok, %{"path" => path, "entries" => entries, "limit" => @list_limit,
              "truncated" => length(names) > @list_limit}}
    else
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  defp dispatch("node.fs.stat", args, opts) do
    with {:ok, path} <- resolve(args["path"], opts),
         {:ok, stat} <- File.stat(path, time: :posix) do
      {:ok, stat_view(path, stat)}
    else
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  defp dispatch("node.fs.read", args, opts) do
    with {:ok, path} <- resolve(args["path"], opts),
         {:ok, offset} <- integer(args, "offset", 0, 0, 9_007_199_254_740_991),
         {:ok, length} <- integer(args, "length", @max_chunk, 1, @max_chunk),
         {:ok, stat} <- regular_file(path),
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      result =
        try do
          case :file.pread(io, offset, length) do
            {:ok, data} -> read_view(path, stat.size, offset, data)
            :eof -> read_view(path, stat.size, offset, "")
            {:error, reason} -> {:error, file_error(reason)}
          end
        after
          :file.close(io)
        end
      result
    else
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  defp dispatch("node.fs.write", args, opts) do
    with {:ok, path} <- resolve(args["path"], opts),
         {:ok, data} <- decode(args["dataBase64"]),
         {:ok, offset} <- integer(args, "offset", 0, 0, 9_007_199_254_740_991),
         {:ok, truncate} <- boolean(args, "truncate", true),
         {:ok, mkdirs} <- boolean(args, "mkdirs", false),
         :ok <- writable_file(path),
         :ok <- maybe_mkdirs(path, mkdirs),
         # Re-resolve after creating parents, before opening the target.
         {:ok, ^path} <- resolve(args["path"], opts),
         {:ok, io} <- :file.open(String.to_charlist(path), [:read, :write, :binary, :raw]) do
      result =
        try do
          with :ok <- :file.pwrite(io, offset, data),
               :ok <- maybe_truncate(io, offset + byte_size(data), truncate),
               {:ok, stat} <- File.stat(path) do
            {:ok, %{"path" => path, "offset" => offset, "bytesWritten" => byte_size(data),
                    "size" => stat.size}}
          else
            {:error, reason} -> {:error, file_error(reason)}
          end
        after
          :file.close(io)
        end
      result
    else
      {:error, reason} -> {:error, file_error(reason)}
      _ -> {:error, :path_not_allowed}
    end
  end

  defp dispatch("node.fs.mkdir", args, opts) do
    with {:ok, path} <- resolve(args["path"], opts),
         :ok <- File.mkdir_p(path) do
      {:ok, %{"path" => path, "created" => true}}
    else
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  defp dispatch("node.fs.move", args, opts) do
    with {:ok, path} <- resolve(args["path"], opts),
         {:ok, destination} <- resolve(args["destination"], opts),
         :ok <- not_root(path, opts),
         :ok <- not_root(destination, opts),
         :ok <- File.rename(path, destination) do
      {:ok, %{"path" => path, "destination" => destination, "moved" => true}}
    else
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  defp dispatch("node.fs.delete", args, opts) do
    # Compare the exact caller spelling, not the expanded/canonical path.
    with true <- is_binary(args["path"]) and args["confirm"] == args["path"],
         {:ok, path} <- resolve(args["path"], opts),
         :ok <- not_root(path, opts),
         {:ok, stat} <- File.lstat(path),
         :ok <- if(stat.type == :directory, do: File.rmdir(path), else: File.rm(path)) do
      {:ok, %{"path" => path, "deleted" => true}}
    else
      false -> {:error, :confirmation_required}
      {:error, :eexist} -> {:error, :directory_not_empty}
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  defp dispatch("node.secrets.set", args, opts) do
    with :ok <- secret_name(args["name"]),
         true <- is_binary(args["value"]) and byte_size(args["value"]) <= @max_chunk,
         {:ok, metadata} <- Secrets.set(args["name"], args["value"], secret_opts(opts)) do
      {:ok, %{"name" => metadata.name, "set" => true}}
    else
      false -> {:error, :invalid_secret_value}
      {:error, reason} -> {:error, secret_error(reason)}
    end
  end

  defp dispatch("node.secrets.list", _args, opts) do
    with {:ok, entries} <- Secrets.list(secret_opts(opts)) do
      {:ok, %{"names" => entries |> Enum.take(@list_limit) |> Enum.map(& &1.name),
              "limit" => @list_limit, "truncated" => length(entries) > @list_limit}}
    else
      {:error, reason} -> {:error, secret_error(reason)}
    end
  end

  defp dispatch("node.secrets.delete", args, opts) do
    with :ok <- secret_name(args["name"]),
         :ok <- Secrets.delete(args["name"], secret_opts(opts)) do
      {:ok, %{"name" => String.trim(args["name"]), "deleted" => true}}
    else
      {:error, reason} -> {:error, secret_error(reason)}
    end
  end

  defp valid_path(path) when is_binary(path) and byte_size(path) in 1..4096 do
    cond do
      not String.valid?(path) or String.contains?(path, <<0>>) -> {:error, :invalid_path}
      ".." in Path.split(path) -> {:error, :path_not_allowed}
      true -> :ok
    end
  end
  defp valid_path(_), do: {:error, :invalid_path}

  defp default_cwd(opts) do
    cwd = Keyword.get(opts, :default_cwd) || System.user_home!()
    with :ok <- valid_path(cwd), do: {:ok, Path.expand(cwd)}
  end

  defp allowed_roots(opts) do
    roots = Keyword.get(opts, :allowed_roots, [System.user_home!()])
    if is_list(roots) and roots != [] and length(roots) <= 64 do
      Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
        with :ok <- valid_path(root),
             lexical = Path.expand(root),
             {:ok, resolved} <- canonical(lexical),
             true <- File.dir?(resolved) do
          {:cont, {:ok, [{lexical, resolved} | acc]}}
        else
          _ -> {:halt, {:error, :invalid_allowed_roots}}
        end
      end)
    else
      {:error, :invalid_allowed_roots}
    end
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, if(root == "/", do: "/", else: root <> "/"))

  # Walk before normalizing symlink targets: a missing leaf cannot hide a
  # symlinked existing parent. Looping links have a finite hop budget.
  defp canonical(path), do: walk(Path.split(path), "/", 40)
  defp walk([], current, _hops), do: {:ok, current}
  defp walk(["/" | rest], _current, hops), do: walk(rest, "/", hops)
  defp walk(["." | rest], current, hops), do: walk(rest, current, hops)
  defp walk([".." | rest], current, hops), do: walk(rest, Path.dirname(current), hops)
  defp walk([part | rest], current, hops) do
    next = Path.join(current, part)
    case File.lstat(next) do
      {:ok, %{type: :symlink}} when hops > 0 ->
        with {:ok, target} <- File.read_link(next) do
          parts = if Path.type(target) == :absolute, do: Path.split(target), else: Path.split(current) ++ Path.split(target)
          walk(parts ++ rest, "/", hops - 1)
        end
      {:ok, %{type: :symlink}} -> {:error, :symlink_loop}
      {:ok, %{type: type}} when rest != [] and type != :directory -> {:error, :not_directory}
      {:ok, _} -> walk(rest, next, hops)
      {:error, :enoent} -> walk(rest, next, hops)
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  defp not_root(path, opts) do
    with {:ok, roots} <- allowed_roots(opts) do
      if Enum.any?(roots, fn {_, root} -> path == root end), do: {:error, :path_not_allowed}, else: :ok
    end
  end

  defp integer(args, key, default, min, max) do
    value = Map.get(args, key, default)
    if is_integer(value) and value >= min and value <= max, do: {:ok, value}, else: {:error, :invalid_request}
  end
  defp boolean(args, key, default) do
    case Map.get(args, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp regular_file(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular} = stat} -> {:ok, stat}
      {:ok, _} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, file_error(reason)}
    end
  end
  defp writable_file(path) do
    case regular_file(path) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end
  defp maybe_mkdirs(path, true), do: File.mkdir_p(Path.dirname(path))
  defp maybe_mkdirs(_, false), do: :ok
  defp maybe_truncate(_io, _size, false), do: :ok
  defp maybe_truncate(io, size, true) do
    with {:ok, _} <- :file.position(io, size), do: :file.truncate(io)
  end
  defp decode(data) when is_binary(data) and byte_size(data) <= @max_base64 do
    case Base.decode64(data) do
      {:ok, bytes} when byte_size(bytes) <= @max_chunk -> {:ok, bytes}
      {:ok, _} -> {:error, :content_too_large}
      :error -> {:error, :invalid_base64}
    end
  end
  defp decode(data) when is_binary(data), do: {:error, :content_too_large}
  defp decode(_), do: {:error, :invalid_base64}

  defp read_view(path, size, offset, data) do
    {:ok, %{"path" => path, "dataBase64" => Base.encode64(data), "offset" => offset,
            "length" => byte_size(data), "size" => size, "mime" => MIME.from_path(path),
            "eof" => offset + byte_size(data) >= size}}
  end
  defp stat_view(path, stat) do
    %{"path" => path, "type" => Atom.to_string(stat.type), "size" => stat.size,
      "mtimeMs" => stat.mtime * 1000, "mode" => stat.mode, "mime" => MIME.from_path(path)}
  end
  defp secret_name(name) when is_binary(name) and byte_size(name) in 1..256 do
    if String.valid?(name) and String.trim(name) != "" and not String.contains?(name, <<0>>), do: :ok, else: {:error, :invalid_secret_name}
  end
  defp secret_name(_), do: {:error, :invalid_secret_name}
  defp secret_opts(opts), do: Keyword.get(opts, :secret_opts, [])
  defp secret_error(reason) when reason in [:invalid_secret_name, :invalid_secret_value, :missing_master_key, :secrets_locked], do: reason
  defp secret_error(_), do: :secret_store_failed

  defp file_error(:enoent), do: :not_found
  defp file_error(reason) when reason in [:eacces, :eperm], do: :permission_denied
  defp file_error(:enotdir), do: :not_directory
  defp file_error(:eisdir), do: :not_regular_file
  defp file_error(:enotempty), do: :directory_not_empty
  defp file_error(:eexist), do: :already_exists
  defp file_error(reason) when reason in [:invalid_request, :invalid_path, :path_not_allowed, :invalid_allowed_roots, :symlink_loop, :not_found, :not_directory, :not_regular_file, :content_too_large, :invalid_base64], do: reason
  defp file_error(_), do: :filesystem_failed
  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, reason}), do: reason
end
