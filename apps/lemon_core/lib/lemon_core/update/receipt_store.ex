defmodule LemonCore.Update.ReceiptStore do
  @moduledoc """
  Private, content-free durable records for managed runtime updates.

  Update receipts deliberately contain only release identity, integrity
  digests, timestamps, and status. They never contain artifact bytes, command
  output, environment values, credentials, or absolute paths. Writes are
  owner-only and atomic. Mutating update operations share one exclusive lock
  under the managed Lemon state directory so separate launcher processes
  cannot flip `versions/current` concurrently.
  """

  alias LemonCore.Paths

  @schema 1
  @max_records 100
  @id_pattern ~r/\A[0-9]{13}-[0-9a-f]{16}\z/

  @type opts :: keyword()

  @spec with_lock(opts(), (-> term())) :: term() | {:error, term()}
  def with_lock(opts, fun) when is_function(fun, 0) do
    lock = Path.join(root(opts), ".operation.lock")

    with :ok <- ensure_private_dir(root(opts)),
         {:ok, io} <- File.open(lock, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(lock, 0o600),
             :ok <- IO.binwrite(io, "lemon-update-lock-v1\n"),
             :ok <- :file.sync(io) do
          fun.()
        else
          {:error, _reason} -> {:error, :update_lock_failed}
        end
      rescue
        _error -> {:error, :update_operation_failed}
      catch
        _kind, _reason -> {:error, :update_operation_failed}
      after
        File.close(io)
        File.rm(lock)
      end
    else
      {:error, :eexist} -> {:error, :update_locked}
      {:error, reason} -> {:error, {:lock_failed, reason}}
    end
  end

  @spec put_checkpoint(map(), opts()) :: {:ok, map()} | {:error, term()}
  def put_checkpoint(fields, opts) when is_map(fields) do
    record =
      fields
      |> safe_record("checkpoint")
      |> Map.put("id", id())

    with :ok <- write_record(checkpoints_dir(opts), record),
         {:ok, ^record} <- fetch_from(checkpoints_dir(opts), record["id"]) do
      {:ok, record}
    end
  end

  @spec fetch_checkpoint(String.t(), opts()) :: {:ok, map()} | {:error, term()}
  def fetch_checkpoint(id, opts), do: fetch_from(checkpoints_dir(opts), id)

  @spec put_receipt(map(), opts()) :: {:ok, map()} | {:error, term()}
  def put_receipt(fields, opts) when is_map(fields) do
    record =
      fields
      |> safe_record("receipt")
      |> Map.put("id", id())

    with :ok <- write_record(receipts_dir(opts), record) do
      prune(receipts_dir(opts))
      {:ok, record}
    end
  end

  @spec fetch_receipt(String.t(), opts()) :: {:ok, map()} | {:error, term()}
  def fetch_receipt(id, opts), do: fetch_from(receipts_dir(opts), id)

  @spec history(opts()) :: {:ok, [map()]} | {:error, term()}
  def history(opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> bounded_limit()
    dir = receipts_dir(opts)

    case File.ls(dir) do
      {:ok, entries} ->
        records =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.sort(:desc)
          |> Enum.take(limit)
          |> Enum.flat_map(fn file ->
            case fetch_from(dir, Path.rootname(file)) do
              {:ok, record} -> [record]
              {:error, _reason} -> []
            end
          end)

        {:ok, records}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:history_failed, reason}}
    end
  end

  @spec root(opts()) :: String.t()
  def root(opts) do
    opts
    |> paths_opts()
    |> Paths.home_state_dir()
    |> Path.join("updates")
  end

  defp receipts_dir(opts), do: Path.join(root(opts), "receipts")
  defp checkpoints_dir(opts), do: Path.join(root(opts), "checkpoints")

  defp paths_opts(opts), do: Keyword.get(opts, :paths_opts, [])

  defp safe_record(fields, kind) do
    fields
    |> Map.take([
      "action",
      "channel",
      "checkpoint_id",
      "created_at_ms",
      "from_version",
      "launcher_sha256",
      "manifest_commit",
      "plan_digest",
      "platform",
      "profile",
      "rollback_digest",
      "rolled_back_receipt_id",
      "status",
      "to_version"
    ])
    |> Map.put("schema", @schema)
    |> Map.put("kind", kind)
  end

  defp write_record(dir, record) do
    path = Path.join(dir, record["id"] <> ".json")
    bytes = Jason.encode_to_iodata!(record, pretty: true)

    with :ok <- ensure_private_dir(dir),
         :ok <- atomic_private_write(path, [bytes, "\n"]) do
      :ok
    end
  end

  defp fetch_from(dir, id) when is_binary(id) do
    if Regex.match?(@id_pattern, id) do
      path = Path.join(dir, id <> ".json")

      with {:ok, %File.Stat{type: :regular, size: size}} when size <= 32_768 <- File.stat(path),
           {:ok, bytes} <- File.read(path),
           {:ok, %{"id" => ^id, "schema" => @schema} = record} <- Jason.decode(bytes) do
        {:ok, record}
      else
        {:ok, %File.Stat{}} -> {:error, :invalid_receipt_file}
        {:error, :enoent} -> {:error, :receipt_not_found}
        {:error, reason} -> {:error, {:receipt_read_failed, reason}}
        _ -> {:error, :invalid_receipt}
      end
    else
      {:error, :invalid_receipt_id}
    end
  end

  defp fetch_from(_dir, _id), do: {:error, :invalid_receipt_id}

  defp atomic_private_write(path, iodata) do
    tmp = path <> ".tmp." <> random_hex(8)

    try do
      with {:ok, io} <- File.open(tmp, [:write, :exclusive, :binary]),
           :ok <- write_and_close(io, tmp, iodata),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} -> {:error, {:receipt_write_failed, reason}}
      end
    after
      File.rm(tmp)
    end
  end

  defp write_and_close(io, path, iodata) do
    result =
      with :ok <- File.chmod(path, 0o600),
           :ok <- IO.binwrite(io, iodata),
           :ok <- :file.sync(io) do
        :ok
      end

    close_result = File.close(io)
    if result == :ok, do: close_result, else: result
  end

  defp ensure_private_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(dir),
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:ok, %File.Stat{}} -> {:error, :unsafe_update_state_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prune(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort(:desc)
        |> Enum.drop(@max_records)
        |> Enum.each(fn file -> File.rm(Path.join(dir, file)) end)

      _ ->
        :ok
    end
  end

  defp bounded_limit(value) when is_integer(value) and value > 0, do: min(value, @max_records)
  defp bounded_limit(_value), do: 20

  defp id do
    Integer.to_string(System.system_time(:millisecond)) <> "-" <> random_hex(8)
  end

  defp random_hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
