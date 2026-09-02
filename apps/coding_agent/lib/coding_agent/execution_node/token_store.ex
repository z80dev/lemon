defmodule CodingAgent.ExecutionNode.TokenStore do
  @moduledoc """
  Private local storage for named execution-node session tokens.

  New records are keyed by durable controller node ID, so a controller-side
  rename cannot strand the local credential. The launch name remains a local
  alias used to discover the record. Name-keyed legacy files are migrated
  atomically when they contain a node ID.
  """

  @dir_mode 0o700
  @file_mode 0o600

  @spec load(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load(node_name, opts \\ []) when is_binary(node_name) do
    case Keyword.get(opts, :node_id) do
      node_id when is_binary(node_id) and node_id != "" ->
        load_node(node_id, opts)

      _ ->
        load_by_alias(node_name, opts)
    end
  end

  @doc "Loads a stable credential directly by durable controller node ID."
  @spec load_node(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load_node(node_id, opts \\ []) when is_binary(node_id) do
    with {:ok, path} <- node_path(node_id, opts),
         {:ok, record} <- read_record(path),
         true <- record["nodeId"] == String.trim(node_id),
         :ok <- exact_controller_match(record, opts) do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :not_found}
      false -> {:error, :node_id_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec save(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save(node_name, attrs, opts \\ []) when is_binary(node_name) and is_map(attrs) do
    token = value(attrs, "token")

    with true <- is_binary(token) and String.trim(token) != "",
         {:ok, path} <- credential_path(node_name, attrs, opts),
         :ok <- ensure_private_directory(Path.dirname(path)),
         record <- build_record(node_name, attrs),
         {:ok, encoded} <- Jason.encode(record),
         :ok <- atomic_private_write(path, encoded),
         :ok <- remove_legacy_file(node_name, attrs, path, opts) do
      :ok
    else
      false -> {:error, :missing_token}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec path(String.t(), keyword()) :: {:ok, Path.t()} | {:error, :invalid_node_name}
  def path(node_name, opts \\ []) when is_binary(node_name) do
    case String.trim(node_name) do
      "" ->
        {:error, :invalid_node_name}

      trimmed ->
        digest = :crypto.hash(:sha256, trimmed) |> Base.encode16(case: :lower)
        {:ok, Path.join(root(opts), digest <> ".json")}
    end
  end

  @doc "Returns the stable node-ID-keyed credential path."
  @spec node_path(String.t(), keyword()) :: {:ok, Path.t()} | {:error, :invalid_node_id}
  def node_path(node_id, opts \\ []) when is_binary(node_id) do
    case String.trim(node_id) do
      "" ->
        {:error, :invalid_node_id}

      trimmed ->
        digest = :crypto.hash(:sha256, trimmed) |> Base.encode16(case: :lower)
        {:ok, Path.join(root(opts), "node-" <> digest <> ".json")}
    end
  end

  defp root(opts) do
    Keyword.get_lazy(opts, :root, fn ->
      LemonCore.Paths.home_path(["nodes", "execution"])
    end)
  end

  defp build_record(node_name, attrs) do
    %{
      "localName" => String.trim(node_name),
      "nodeName" => String.trim(node_name),
      "token" => value(attrs, "token"),
      "nodeId" => value(attrs, "nodeId"),
      "controller" => value(attrs, "controller"),
      "recoveryToken" => value(attrs, "recoveryToken"),
      "storedAtMs" => System.system_time(:millisecond)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp value(map, "token"), do: Map.get(map, "token") || Map.get(map, :token)
  defp value(map, "nodeId"), do: Map.get(map, "nodeId") || Map.get(map, :node_id)

  defp value(map, "controller"),
    do: Map.get(map, "controller") || Map.get(map, :controller)

  defp value(map, "recoveryToken"),
    do: Map.get(map, "recoveryToken") || Map.get(map, :recovery_token)

  defp credential_path(node_name, attrs, opts) do
    case value(attrs, "nodeId") do
      node_id when is_binary(node_id) and node_id != "" -> node_path(node_id, opts)
      _ -> path(node_name, opts)
    end
  end

  defp load_by_alias(node_name, opts) do
    alias_name = String.trim(node_name)
    controller = Keyword.get(opts, :controller)

    matches =
      root(opts)
      |> Path.join("node-*.json")
      |> Path.wildcard()
      |> Enum.reduce([], fn path, acc ->
        case read_record(path) do
          {:ok, record} ->
            if alias_matches?(record, alias_name, controller), do: [record | acc], else: acc

          {:error, _reason} ->
            acc
        end
      end)

    case matches do
      [record] -> {:ok, record}
      [] -> load_legacy_and_migrate(alias_name, opts)
      _ -> {:error, :ambiguous_node_alias}
    end
  end

  defp load_legacy_and_migrate(node_name, opts) do
    with {:ok, legacy_path} <- path(node_name, opts),
         {:ok, record} <- read_record(legacy_path),
         true <- record["nodeName"] == node_name,
         :ok <- maybe_migrate_legacy(node_name, record, opts) do
      case record["nodeId"] do
        node_id when is_binary(node_id) and node_id != "" -> load_node(node_id, opts)
        _ -> {:ok, record}
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      false -> {:error, :node_name_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_migrate_legacy(node_name, %{"nodeId" => node_id} = record, opts)
       when is_binary(node_id) and node_id != "" do
    save(node_name, record, opts)
  end

  defp maybe_migrate_legacy(_node_name, _record, _opts), do: :ok

  defp alias_matches?(record, alias_name, controller) do
    stored_alias = record["localName"] || record["nodeName"]
    controller_matches = is_nil(controller) or record["controller"] == controller
    stored_alias == alias_name and controller_matches
  end

  defp exact_controller_match(record, opts) do
    case Keyword.get(opts, :controller) do
      controller when is_binary(controller) and controller != "" ->
        if record["controller"] == controller, do: :ok, else: {:error, :controller_mismatch}

      _ ->
        {:error, :controller_required}
    end
  end

  defp read_record(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, record} when is_map(record) <- Jason.decode(raw),
         token when is_binary(token) and token != "" <- record["token"] do
      {:ok, record}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_token_file}
      nil -> {:error, :missing_token}
      "" -> {:error, :missing_token}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token_file}
    end
  end

  defp remove_legacy_file(node_name, attrs, stable_path, opts) do
    with {:ok, legacy_path} <- path(node_name, opts),
         false <- legacy_path == stable_path,
         {:ok, legacy_record} <- read_record(legacy_path),
         true <- legacy_record["nodeId"] == value(attrs, "nodeId") do
      case File.rm(legacy_path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      true -> :ok
      false -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_private_directory(path) do
    with :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, @dir_mode) do
      :ok
    end
  end

  defp atomic_private_write(path, contents) do
    suffix = System.unique_integer([:positive, :monotonic])
    temporary = path <> ".tmp-#{suffix}"

    result =
      with {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]),
           :ok <- File.chmod(temporary, @file_mode),
           :ok <- write_and_close(io, contents),
           :ok <- File.rename(temporary, path),
           :ok <- File.chmod(path, @file_mode) do
        :ok
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp write_and_close(io, contents) do
    write_result = IO.binwrite(io, contents)
    close_result = File.close(io)

    case {write_result, close_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _} -> {:error, reason}
      {_, {:error, reason}} -> {:error, reason}
    end
  end
end
