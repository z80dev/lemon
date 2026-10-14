defmodule CodingAgent.ExecutionNode.HostIO do
  @moduledoc """
  Destination-local host, bounded file transfer and write-only secret operations.

  `handle/3` accepts JSON maps and returns JSON maps or safe error atoms. Paths
  resolve relative to `:default_cwd` (home by default), within `:allowed_roots`
  (home by default). Options are worker-owned, never supplied by RPC callers.
  Filesystem operations use a worker-owned descriptor service, not path admission
  followed by unsafe path-based opens. `resolve/2` is only shell cwd admission.
  """

  alias CodingAgent.ExecutionNode.HostInfo
  alias LemonCore.Secrets

  @max_chunk 1_048_576
  @list_limit 500
  @methods ~w(node.host.info node.fs.list node.fs.stat node.fs.read node.fs.write node.fs.mkdir node.fs.move node.fs.delete.preview node.fs.delete node.secrets.set node.secrets.receipt node.secrets.list node.secrets.delete)

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

  defp dispatch("node.fs." <> _ = method, args, opts) do
    CodingAgent.ExecutionNode.FileService.handle(method, args, opts)
  end

  defp dispatch("node.secrets.set", args, opts) do
    with :ok <- secret_name(args["name"]),
         true <- is_binary(args["value"]) and byte_size(args["value"]) <= @max_chunk,
         {:ok, metadata} <- Secrets.set(args["name"], args["value"], secret_set_opts(args, opts)) do
      result = %{"name" => metadata.name, "set" => true}

      if Map.has_key?(args, "operationId"),
        do: {:ok, Map.merge(result, %{"operationId" => metadata.operation_id,
              "status" => metadata.status, "currentBindingMatches" => metadata.current_binding_matches})},
        else: {:ok, result}
    else
      false -> {:error, :invalid_secret_value}
      {:error, reason} -> {:error, secret_error(reason)}
    end
  end

  defp dispatch("node.secrets.receipt", args, opts) do
    with {:ok, receipt} <- Secrets.receipt(args["operationId"], secret_opts(opts)) do
      {:ok, %{"nodeId" => receipt.node_id, "operationId" => receipt.operation_id,
              "status" => receipt.status, "name" => receipt.name,
              "currentBindingMatches" => receipt.current_binding_matches}}
    else
      {:error, reason} -> {:error, secret_error(reason)}
    end
  end

  defp dispatch("node.secrets.list", _args, opts) do
    {:ok, entries} = Secrets.list(secret_opts(opts))
    {:ok, %{"names" => entries |> Enum.take(@list_limit) |> Enum.map(& &1.name),
            "limit" => @list_limit, "truncated" => length(entries) > @list_limit}}
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
    cwd = Keyword.get(opts, :default_cwd) || home(opts)
    with :ok <- valid_path(cwd), do: {:ok, Path.expand(cwd)}
  end

  defp allowed_roots(opts) do
    roots = Keyword.get(opts, :allowed_roots, [home(opts)])
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

  defp home(opts), do: Keyword.get(opts, :home) || System.user_home!()

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
  defp file_error(reason) when reason in [:eacces, :eperm], do: :permission_denied
  defp file_error(:enotdir), do: :not_directory
  defp file_error(_), do: :filesystem_failed

  defp secret_name(name) when is_binary(name) and byte_size(name) in 1..256 do
    if String.valid?(name) and String.trim(name) != "" and not String.contains?(name, <<0>>), do: :ok, else: {:error, :invalid_secret_name}
  end
  defp secret_name(_), do: {:error, :invalid_secret_name}
  defp secret_opts(opts) do
    opts
    |> Keyword.get(:secret_opts, [])
    |> Keyword.delete(:operation_id)
    |> Keyword.put(:node_id, opts[:node_id])
  end

  defp secret_set_opts(args, opts) do
    if Map.has_key?(args, "operationId"),
      do: Keyword.put(secret_opts(opts), :operation_id, args["operationId"]),
      else: secret_opts(opts)
  end

  defp secret_error(reason) when reason in [:invalid_secret_name, :invalid_secret_value,
    :missing_master_key, :secrets_locked, :invalid_operation_id, :invalid_node_id,
    :secret_operation_conflict, :secret_receipt_capacity, :secret_store_failed], do: reason
  defp secret_error(_), do: :secret_store_failed

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, reason}), do: reason
end
