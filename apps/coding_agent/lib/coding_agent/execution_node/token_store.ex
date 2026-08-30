defmodule CodingAgent.ExecutionNode.TokenStore do
  @moduledoc """
  Private local storage for named execution-node session tokens.

  Node names are hashed before becoming filenames. The JSON record retains the
  original name so callers can detect an unexpected mismatch without putting
  user-controlled path fragments on disk.
  """

  @dir_mode 0o700
  @file_mode 0o600

  @spec load(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load(node_name, opts \\ []) when is_binary(node_name) do
    with {:ok, path} <- path(node_name, opts),
         {:ok, raw} <- File.read(path),
         {:ok, record} when is_map(record) <- Jason.decode(raw),
         true <- record["nodeName"] == String.trim(node_name),
         token when is_binary(token) and token != "" <- record["token"] do
      {:ok, record}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_token_file}
      false -> {:error, :node_name_mismatch}
      nil -> {:error, :missing_token}
      "" -> {:error, :missing_token}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token_file}
    end
  end

  @spec save(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def save(node_name, attrs, opts \\ []) when is_binary(node_name) and is_map(attrs) do
    token = value(attrs, "token")

    with true <- is_binary(token) and String.trim(token) != "",
         {:ok, path} <- path(node_name, opts),
         :ok <- ensure_private_directory(Path.dirname(path)),
         record <- build_record(node_name, attrs),
         {:ok, encoded} <- Jason.encode(record),
         :ok <- atomic_private_write(path, encoded) do
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

  defp root(opts) do
    Keyword.get_lazy(opts, :root, fn ->
      Path.join([System.user_home!(), ".lemon", "nodes", "execution"])
    end)
  end

  defp build_record(node_name, attrs) do
    %{
      "nodeName" => String.trim(node_name),
      "token" => value(attrs, "token"),
      "nodeId" => value(attrs, "nodeId"),
      "controller" => value(attrs, "controller"),
      "storedAtMs" => System.system_time(:millisecond)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp value(map, "token"), do: Map.get(map, "token") || Map.get(map, :token)
  defp value(map, "nodeId"), do: Map.get(map, "nodeId") || Map.get(map, :node_id)

  defp value(map, "controller"),
    do: Map.get(map, "controller") || Map.get(map, :controller)

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
