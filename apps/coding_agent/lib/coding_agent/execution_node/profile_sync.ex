defmodule CodingAgent.ExecutionNode.ProfileSync do
  @moduledoc """
  Persists controller-owned persona revisions in a destination-owned profile home.

  Only the four persona files, `persona-revision.json` and
  `persona-sync-receipt.json` are managed. Local config, credentials, USER.md,
  memory, tools and skills are never copied or overwritten. Files are replaced
  atomically and the revision is committed last after rereading actual files.

  Before persona writes, the latest non-null mutation/digest is durably reserved.
  Reusing that retained mutation with another digest conflicts even after an
  interrupted write. There is no historical mutation ledger. Null mutations do
  not erase the retained binding; a completed different revision supersedes it.
  `status/2` only reads that binding and the committed revision/files. It never
  provisions paths, resends persona, repairs corruption or advances a receipt.
  """

  import Kernel, except: [apply: 2]

  alias LemonCore.{ProfileSnapshot, ProfileStore}

  # JSON may expand each allowed text byte to six bytes (\u0001). Cover the
  # 128 KiB prompt, four 64 KiB files and bounded metadata without truncation.
  @record_limit 2_400_000

  @spec apply(map(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def apply(args, _cwd \\ nil) do
    with :ok <- ProfileSnapshot.validate(args),
         {:ok, paths} <- ProfileStore.paths(args["profileId"]) do
      :global.trans({{__MODULE__, paths["home"]}, self()}, fn -> persist(args, paths) end)
      |> normalize_result()
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :profile_sync_failed}
  catch
    _, _ -> {:error, :profile_sync_failed}
  end

  @spec status(map(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def status(args, _cwd \\ nil) do
    with :ok <- ProfileSnapshot.validate_status(args),
         {:ok, paths} <- ProfileStore.paths(args["profileId"]) do
      :global.trans({{__MODULE__, paths["home"]}, self()}, fn -> lookup_status(args, paths) end)
      |> normalize_result()
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :profile_sync_failed}
  catch
    _, _ -> {:error, :profile_sync_failed}
  end

  defp lookup_status(args, paths) do
    marker = Path.join(paths["home"], "persona-revision.json")
    receipt_path = Path.join(paths["home"], "persona-sync-receipt.json")

    with :ok <- safe_file(marker),
         :ok <- safe_file(receipt_path),
         {:ok, receipt} <- read_receipt(receipt_path),
         {:ok, committed} <- read_record(marker),
         :ok <- matching_profile(receipt, args),
         :ok <- matching_profile(committed, args),
         :ok <- validate_committed(receipt, committed, paths) do
      receipt_status(args, receipt, committed)
    end
  end

  defp validate_committed(nil, nil, _paths), do: :ok
  defp validate_committed(%{"status" => "pending"}, nil, _paths), do: :ok
  defp validate_committed(_receipt, nil, _paths), do: {:error, :profile_sync_corrupt}
  defp validate_committed(%{"status" => "pending", "revisionDigest" => digest}, committed, paths) do
    if digest == committed["revisionDigest"], do: verify_files(committed, paths), else: :ok
  end
  defp validate_committed(_receipt, committed, paths), do: verify_files(committed, paths)

  defp receipt_status(args, nil, _committed), do: status_result(args, "unknown")
  defp receipt_status(args, receipt, committed) do
    cond do
      receipt["mutationId"] != args["mutationId"] or
          receipt["revisionDigest"] != args["revisionDigest"] ->
        status_result(args, "unknown")

      receipt["status"] == "superseded" ->
        status_result(args, "unknown")

      committed != nil and committed["revisionDigest"] == args["revisionDigest"] ->
        status_result(args, "acknowledged")

      receipt["status"] == "pending" ->
        status_result(args, "pending")

      committed == nil ->
        {:error, :profile_sync_corrupt}

      true ->
        status_result(args, "unknown")
    end
  end

  defp status_result(args, status) do
    {:ok, %{
      "profileId" => args["profileId"],
      "mutationId" => args["mutationId"],
      "status" => status,
      "acknowledged" => status == "acknowledged",
      "revisionDigest" => if(status == "unknown", do: nil, else: args["revisionDigest"])
    }}
  end

  defp persist(args, paths) do
    marker = Path.join(paths["home"], "persona-revision.json")
    receipt_path = Path.join(paths["home"], "persona-sync-receipt.json")
    dirs = Enum.map(~w(home workspace memory skills sessions), &paths[&1])
    files = Enum.map(ProfileSnapshot.filenames(), &Path.join(paths["workspace"], &1))

    with :ok <- each(dirs, &safe_directory/1),
         :ok <- each([marker, receipt_path, paths["config"], paths["manifest"] | files], &safe_file/1),
         {:ok, previous} <- read_record(marker),
         {:ok, receipt} <- read_receipt(receipt_path),
         :ok <- check_mutation(receipt, args),
         :ok <- matching_profile(previous, args),
         :ok <- matching_profile(receipt, args),
         :ok <- each(dirs, &ensure_directory/1),
         {:ok, reserved} <- reserve(receipt_path, receipt, args),
         :ok <- persist_persona(previous, args, paths),
         :ok <- atomic_write(marker, Jason.encode!(args)),
         {:ok, ^args} <- read_record(marker),
         :ok <- verify_files(args, paths) do
      with :ok <- complete_receipt(receipt_path, reserved, args) do
        {:ok, Map.take(args, ~w(profileId mutationId revisionDigest)) |> Map.put("acknowledged", true)}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :profile_sync_corrupt}
    end
  end

  defp persist_persona(%{"revisionDigest" => digest}, %{"revisionDigest" => digest} = args, paths),
    do: verify_files(args, paths)

  defp persist_persona(_previous, args, paths) do
    with :ok <- each(ProfileSnapshot.filenames(), fn name ->
           path = Path.join(paths["workspace"], name)

           case Map.fetch(args["personaInstructions"], name) do
             {:ok, text} -> atomic_write(path, text)
             :error -> remove_persona(path)
           end
         end) do
      verify_files(args, paths)
    end
  end

  defp verify_files(args, paths) do
    each(ProfileSnapshot.filenames(), fn name ->
      path = Path.join(paths["workspace"], name)

      with :ok <- safe_file(path) do
        case {Map.fetch(args["personaInstructions"], name), read_persona(path)} do
          {{:ok, text}, {:ok, text}} -> :ok
          {:error, {:error, :enoent}} -> :ok
          _ -> {:error, :profile_sync_corrupt}
        end
      end
    end)
  end

  defp read_persona(path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:error, :enoent}
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 65_536 -> File.read(path)
      _ -> {:error, :profile_sync_corrupt}
    end
  end

  defp reserve(_path, receipt, %{"mutationId" => nil}), do: {:ok, receipt}
  defp reserve(path, receipt, args) do
    if receipt != nil and receipt["mutationId"] == args["mutationId"] do
      {:ok, receipt}
    else
      reserved = Map.take(args, ~w(profileId mutationId revisionDigest)) |> Map.put("status", "pending")
      with :ok <- write_receipt(path, reserved), do: {:ok, reserved}
    end
  end

  defp complete_receipt(_path, nil, _args), do: :ok
  defp complete_receipt(path, receipt, args) do
    status = if receipt["revisionDigest"] == args["revisionDigest"], do: "acknowledged", else: "superseded"
    write_receipt(path, Map.put(receipt, "status", status))
  end

  defp write_receipt(path, receipt) do
    with :ok <- atomic_write(path, Jason.encode!(receipt)),
         {:ok, ^receipt} <- read_receipt(path) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :profile_sync_corrupt}
    end
  end

  defp read_receipt(path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, nil}
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 2_048 ->
        with {:ok, bytes} <- File.read(path),
             {:ok, receipt} when is_map(receipt) <- Jason.decode(bytes),
             true <- Enum.sort(Map.keys(receipt)) == Enum.sort(~w(profileId mutationId revisionDigest status)),
             :ok <- ProfileSnapshot.validate_status(Map.take(receipt, ~w(profileId mutationId revisionDigest))),
             true <- receipt["status"] in ~w(pending acknowledged superseded) do
          {:ok, receipt}
        else
          _ -> {:error, :profile_sync_corrupt}
        end
      _ -> {:error, :profile_sync_corrupt}
    end
  end

  defp check_mutation(nil, _args), do: :ok
  defp check_mutation(previous, args) do
    if not is_nil(args["mutationId"]) and previous["mutationId"] == args["mutationId"] and
         previous["revisionDigest"] != args["revisionDigest"],
      do: {:error, :mutation_conflict},
      else: :ok
  end

  defp matching_profile(nil, _args), do: :ok
  defp matching_profile(record, args) do
    if record["profileId"] == args["profileId"], do: :ok, else: {:error, :profile_sync_corrupt}
  end

  defp read_record(path) do
    case File.lstat(path) do
      {:error, :enoent} -> {:ok, nil}
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @record_limit ->
        with {:ok, bytes} <- File.read(path),
             {:ok, record} when is_map(record) <- Jason.decode(bytes),
             :ok <- ProfileSnapshot.validate(record) do
          {:ok, record}
        else
          _ -> {:error, :profile_sync_corrupt}
        end
      _ -> {:error, :profile_sync_corrupt}
    end
  end


  # Check every ancestor, not merely the profile leaf. Missing components are
  # allowed only until creation; symlinks and non-directory boundaries fail closed.
  defp safe_directory(path) do
    parent = Path.dirname(path)

    with :ok <- if(parent == path, do: :ok, else: safe_directory(parent)) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:error, :enoent} -> :ok
        _ -> {:error, :unsafe_profile_boundary}
      end
    end
  end

  defp safe_file(path) do
    with :ok <- safe_directory(Path.dirname(path)) do
      case File.lstat(path) do
        {:error, :enoent} -> :ok
        {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
        _ -> {:error, :unsafe_profile_boundary}
      end
    end
  end

  defp ensure_directory(path) do
    with :ok <- safe_directory(path) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:error, :enoent} ->
          with :ok <- ensure_directory(Path.dirname(path)),
               :ok <- File.mkdir(path),
               :ok <- File.chmod(path, 0o700) do
            :ok
          else
            _ -> {:error, :profile_sync_failed}
          end
        _ -> {:error, :unsafe_profile_boundary}
      end
    end
  end

  defp atomic_write(path, bytes) do
    temp = Path.join(Path.dirname(path), ".persona-sync-#{System.unique_integer([:positive])}")

    try do
      with :ok <- safe_file(path),
           {:ok, io} <- File.open(temp, [:write, :binary, :exclusive]) do
        result =
          try do
            with :ok <- File.chmod(temp, 0o600),
                 :ok <- IO.binwrite(io, bytes),
                 :ok <- :file.sync(io) do
              :ok
            end
          after
            File.close(io)
          end

        with :ok <- result,
             :ok <- safe_file(path),
             :ok <- File.rename(temp, path) do
          :ok
        else
          _ -> {:error, :profile_sync_failed}
        end
      else
        {:error, :unsafe_profile_boundary} = error -> error
        _ -> {:error, :profile_sync_failed}
      end
    after
      File.rm(temp)
    end
  end

  defp remove_persona(path) do
    with :ok <- safe_file(path) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        _ -> {:error, :profile_sync_failed}
      end
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_result({:ok, _} = result), do: result
  defp normalize_result({:error, _} = result), do: result
  defp normalize_result(_), do: {:error, :profile_sync_failed}
end
