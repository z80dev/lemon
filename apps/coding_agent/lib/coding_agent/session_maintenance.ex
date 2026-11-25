defmodule CodingAgent.SessionMaintenance do
  @moduledoc false

  alias CodingAgent.{Config, SessionRegistry}
  alias CodingAgent.Session.Ownership

  @root_lock {__MODULE__, :root_lock}
  # Maintenance reads headers only; this operator policy bounds corrupt headers.
  @header_bytes 65_536
  @hash_chunk_bytes 65_536

  # Writers/startups may proceed together; only maintenance needs an exclusive
  # root snapshot. A common requester lets :global track every shared holder
  # independently and release its admission on death. Nested calls must not
  # release an outer transaction's lock.
  def with_root_lock(fun, mode \\ :shared) when mode in [:shared, :exclusive] do
    root = root()

    case Process.get(@root_lock) do
      {^root, :exclusive} -> fun.()
      {^root, ^mode} -> fun.()
      {^root, :shared} -> {:error, :lock_upgrade}
      previous -> lock_root(root, mode, previous, fun)
    end
  end

  defp lock_root(root, mode, previous, fun) do
    requester = if mode == :shared, do: {__MODULE__, :shared}, else: self()

    result =
      :global.trans(
        {{__MODULE__, root}, requester},
        fn ->
          Process.put(@root_lock, {root, mode})

          try do
            fun.()
          after
            if previous, do: Process.put(@root_lock, previous), else: Process.delete(@root_lock)
          end
        end,
        [node()],
        3
      )

    case result do
      :aborted -> {:error, :lock_timeout}
      result -> result
    end
  end

  # A dry run takes no root admission: it must never stall session startup,
  # artifact spill or guardrails. It binds every journal and spill file to a
  # stat fingerprint and hashes only the candidates it would mutate.
  def plan(cutoff) when is_integer(cutoff) and cutoff > 0 do
    guarded(fn -> snapshot(root(), cutoff, true) end)
  end

  # Re-hash candidates before admission, then compare stat fingerprints (no
  # file content) while holding the exclusive root lock for the mutation.
  def execute(%{root: root, older_than_ms: cutoff} = expected) do
    guarded(fn ->
      with true <- root == root(),
           {:ok, hashed} <- snapshot(root, cutoff, true),
           true <- hashed == expected do
        with_root_lock(fn -> execute_locked(root, cutoff, expected) end, :exclusive)
      else
        {:error, _} = error -> error
        _ -> {:error, :confirmation_mismatch}
      end
    end)
  end

  defp execute_locked(root, cutoff, expected) do
    with {:ok, initial} <- snapshot(root, cutoff, false) do
      paths = Enum.map(initial.journals, & &1.path)

      with_files(Enum.sort(paths), fn ->
        with {:ok, current} <- snapshot(root, cutoff, false),
             true <- current == without_digests(expected) do
          execute_candidates(current)
        else
          _ -> {:error, :confirmation_mismatch}
        end
      end)
    end
  end

  defp without_digests(plan) do
    Map.update!(plan, :candidates, fn candidates ->
      Enum.map(candidates, fn
        %{kind: :archive} = candidate ->
          Map.update!(candidate, :revision, &Map.delete(&1, :digest))

        %{kind: :orphan_artifact} = candidate ->
          Map.update!(candidate, :entries, fn entries ->
            Enum.map(entries, &Map.update!(&1, :revision, fn r -> Map.delete(r, :digest) end))
          end)
      end)
    end)
  end

  defp snapshot(root, cutoff, hash?) do
    with :ok <- directory_or_missing(Path.dirname(root)),
         {:ok, names} <- children(root) do
      directories =
        names
        |> Enum.filter(&(String.starts_with?(&1, "--") and String.ends_with?(&1, "--")))
        |> Enum.map(&Path.join(root, &1))
        |> Enum.sort()

      with {:ok, workspaces} <- collect(directories, &workspace(root, &1, cutoff)),
           candidates = Enum.flat_map(workspaces, & &1.candidates),
           {:ok, candidates} <-
             if(hash?, do: collect(candidates, &digest/1), else: {:ok, candidates}) do
        {:ok,
         %{
           root: root,
           older_than_ms: cutoff,
           directories: directories,
           journals: Enum.flat_map(workspaces, & &1.journals),
           inventory: Enum.map(workspaces, & &1.inventory),
           candidates: candidates
         }}
      end
    end
  end

  # Content digests bind the files a confirmed run may archive or delete.
  defp digest(%{kind: :archive, path: path, revision: revision} = candidate) do
    with {:ok, revision} <- digest_file(path, revision),
         do: {:ok, %{candidate | revision: revision}}
  end

  defp digest(%{kind: :orphan_artifact, entries: entries} = candidate) do
    entries
    |> collect(fn
      %{type: :regular, path: path, revision: revision} = entry ->
        with {:ok, revision} <- digest_file(path, revision),
             do: {:ok, %{entry | revision: revision}}

      entry ->
        {:ok, entry}
    end)
    |> case do
      {:ok, entries} -> {:ok, %{candidate | entries: entries}}
      error -> error
    end
  end

  defp workspace(root, directory, cutoff) do
    with {:ok, names} <- children(directory),
         {:ok, live} <- journals(root, directory, names, false),
         archive = Path.join(directory, "archive"),
         {:ok, archive_names} <- children(archive),
         {:ok, archived} <- journals(root, archive, archive_names, true),
         spill_root = Path.join(directory, "spill"),
         {:ok, spill_names} <- children(spill_root),
         {:ok, spills} <- collect(spill_names, &spill(root, Path.join(spill_root, &1))) do
      journals = live ++ archived
      active_paths = active_paths(directory)

      protected =
        journals
        |> Enum.map(fn journal -> Path.basename(Config.spill_dir(journal.cwd, journal.id)) end)
        |> Enum.concat(Enum.map(SessionRegistry.list_ids(), &spill_name/1))
        |> MapSet.new()

      # A live owner may not have persisted a header yet, or may use a hashed
      # filename. Without its native identity, retain every spill in that cwd.
      unknown_owner? =
        Enum.any?(active_paths, fn path ->
          not Enum.any?(journals, &(&1.path == path))
        end)

      archives =
        live
        |> Enum.filter(fn journal ->
          not journal.active and journal.updated_at_ms < cutoff and
            not Enum.any?(archived, &(Path.basename(&1.path) == Path.basename(journal.path)))
        end)
        |> Enum.map(fn journal ->
          %{
            kind: :archive,
            id: journal.id,
            path: journal.path,
            destination: Path.join(archive, Path.basename(journal.path)),
            bytes: journal.revision.size,
            revision: journal.revision
          }
        end)

      orphans =
        spills
        |> Enum.reject(&(unknown_owner? or MapSet.member?(protected, Path.basename(&1.path))))
        |> Enum.map(fn spill ->
          %{
            kind: :orphan_artifact,
            id: Path.relative_to(spill.path, root),
            path: spill.path,
            bytes: Enum.reduce(spill.entries, 0, fn entry, n -> n + entry.revision.size end),
            entries: spill.entries
          }
        end)

      {:ok,
       %{
         journals: journals,
         inventory: %{
           directory: directory,
           journals: journals,
           spills: spills,
           active: active_paths
         },
         candidates: archives ++ orphans
       }}
    end
  end

  defp journals(root, directory, names, archived?) do
    names
    |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
    |> collect(fn name ->
      path = Path.join(directory, name)

      with :ok <- confined(root, path),
           {:ok, revision} <- revision(path),
           {:ok, header} <- header(path),
           true <-
             Path.expand(Config.sessions_dir(header["cwd"])) ==
               if(archived?, do: Path.dirname(directory), else: directory) do
        {:ok,
         %{
           path: path,
           id: header["id"],
           cwd: header["cwd"],
           revision: revision,
           updated_at_ms: max(revision.mtime * 1000, timestamp(header["timestamp"])),
           active: is_pid(Ownership.owner(path))
         }}
      else
        _ -> {:error, :maintenance_unavailable}
      end
    end)
  end

  defp header(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, @header_bytes) do
          data when is_binary(data) ->
            case :binary.split(data, "\n") do
              [line, _] ->
                case Jason.decode(line) do
                  {:ok, %{"type" => "session", "id" => id, "cwd" => cwd} = header}
                  when is_binary(id) and id != "" and is_binary(cwd) and cwd != "" ->
                    {:ok, header}

                  _ ->
                    {:error, :maintenance_unavailable}
                end

              _ ->
                {:error, :maintenance_unavailable}
            end

          _ ->
            {:error, :maintenance_unavailable}
        end
      after
        File.close(file)
      end
    end
  end

  defp timestamp(value) when is_integer(value), do: value

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond)
      _ -> throw(:maintenance_unavailable)
    end
  end

  defp timestamp(_), do: throw(:maintenance_unavailable)

  defp spill(root, path) do
    with {:ok, entries} <- tree(root, path) do
      {:ok, %{path: path, entries: entries}}
    end
  end

  defp tree(root, path) do
    with :ok <- confined(root, path),
         {:ok, stat} <- File.lstat(path, time: :posix) do
      case stat.type do
        :directory ->
          with {:ok, names} <- children(path),
               {:ok, nested} <- collect(names, &tree(root, Path.join(path, &1))) do
            {:ok,
             [
               %{path: path, type: :directory, revision: directory_revision(stat)}
               | List.flatten(nested)
             ]}
          end

        :regular ->
          with {:ok, revision} <- revision(path) do
            {:ok, [%{path: path, type: :regular, revision: revision}]}
          end

        _ ->
          {:error, :maintenance_unavailable}
      end
    end
  end

  defp revision(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, file_identity(stat)}
      _ -> {:error, :maintenance_unavailable}
    end
  end

  defp digest_file(path, revision) do
    with digest <-
           File.stream!(path, @hash_chunk_bytes, [:raw, :binary])
           |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
           |> :crypto.hash_final(),
         {:ok, ^revision} <- revision(path) do
      {:ok, Map.put(revision, :digest, digest)}
    else
      _ -> {:error, :maintenance_unavailable}
    end
  end

  defp file_identity(stat),
    do:
      Map.take(stat, [:inode, :major_device, :minor_device, :size, :mtime, :ctime, :mode, :links])

  defp directory_revision(stat), do: stat |> file_identity() |> Map.put(:size, 0)

  defp children(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.ls(path) do
          {:ok, names} -> {:ok, Enum.sort(names)}
          _ -> {:error, :maintenance_unavailable}
        end

      {:error, :enoent} ->
        {:ok, []}

      _ ->
        {:error, :maintenance_unavailable}
    end
  end

  defp directory_or_missing(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :maintenance_unavailable}
    end
  end

  defp confined(root, path) do
    relative = Path.relative_to(path, root)

    if relative == path or relative == ".." or String.starts_with?(relative, "../") do
      {:error, :maintenance_unavailable}
    else
      parts = Path.split(relative)

      Enum.reduce_while([Path.dirname(root), root | ancestor_paths(root, parts)], :ok, fn part,
                                                                                          :ok ->
        case File.lstat(part) do
          {:ok, %{type: type}} when type in [:directory, :regular] -> {:cont, :ok}
          _ -> {:halt, {:error, :maintenance_unavailable}}
        end
      end)
    end
  end

  defp ancestor_paths(_root, []), do: []

  defp ancestor_paths(root, [part | rest]) do
    path = Path.join(root, part)
    [path | ancestor_paths(path, rest)]
  end

  defp active_paths(directory) do
    :global.registered_names()
    |> Enum.flat_map(fn
      {Ownership, owner_node, path} when owner_node == node() and is_binary(path) ->
        if String.starts_with?(path, directory <> "/") and is_pid(Ownership.owner(path)),
          do: [path],
          else: []

      _ ->
        []
    end)
    |> Enum.sort()
  end

  defp spill_name(id), do: Path.basename(Config.spill_dir("/", id))

  defp execute_candidates(plan) do
    initial = %{archived_count: 0, swept_count: 0, verified: false}

    result =
      Enum.reduce_while(plan.candidates, {:ok, initial}, fn candidate, {:ok, counts} ->
        case guarded(fn -> mutate(plan.root, candidate) end) do
          :ok ->
            key = if candidate.kind == :archive, do: :archived_count, else: :swept_count
            {:cont, {:ok, Map.update!(counts, key, &(&1 + 1))}}

          {:error, :archived} ->
            counts = Map.update!(counts, :archived_count, &(&1 + 1))
            {:halt, {:error, {:partial_failure, counts}}}

          _ ->
            {:halt, {:error, {:partial_failure, counts}}}
        end
      end)

    case result do
      {:ok, counts} -> {:ok, %{counts | verified: true}}
      error -> error
    end
  end

  defp mutate(root, %{kind: :archive} = candidate) do
    archive = Path.dirname(candidate.destination)

    with nil <- Ownership.owner(candidate.path),
         :ok <- confined(root, candidate.path),
         {:ok, revision} <- revision(candidate.path),
         true <- revision == candidate.revision,
         :ok <- ensure_archive(archive),
         :ok <- confined(root, archive),
         {:error, :enoent} <- File.lstat(candidate.destination),
         :ok <- File.rename(candidate.path, candidate.destination) do
      result =
        guarded(fn ->
          with {:error, :enoent} <- File.lstat(candidate.path),
               {:ok, archived} <- revision(candidate.destination),
               # rename(2) keeps the inode and content; only ctime may move.
               true <- Map.delete(archived, :ctime) == Map.delete(revision, :ctime) do
            :ok
          end
        end)

      if result == :ok, do: :ok, else: {:error, :archived}
    else
      _ -> {:error, :maintenance_unavailable}
    end
  end

  defp mutate(root, %{kind: :orphan_artifact} = candidate) do
    with {:ok, entries} <- tree(root, candidate.path),
         true <- entries == candidate.entries do
      # Delete only the exact snapshotted files; never follow artifact index
      # targets or use recursive rm, which could sweep newly-created content.
      entries
      |> Enum.reverse()
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        result =
          with :ok <- confined(root, entry.path) do
            case entry.type do
              :regular ->
                with {:ok, current} <- revision(entry.path),
                     true <- current == entry.revision do
                  File.rm(entry.path)
                end

              :directory ->
                File.rmdir(entry.path)
            end
          end

        if result == :ok, do: {:cont, :ok}, else: {:halt, {:error, :maintenance_unavailable}}
      end)
    else
      _ -> {:error, :maintenance_unavailable}
    end
  end

  defp ensure_archive(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> directory_or_missing(path)
      error -> error
    end
  end

  defp with_files([], fun), do: fun.()

  defp with_files([path | rest], fun),
    do: Ownership.with_file(path, fn -> with_files(rest, fun) end)

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp root, do: Path.expand(Path.join(Config.agent_dir(), "sessions"))

  defp guarded(fun) do
    case fun.() do
      :aborted -> {:error, :maintenance_unavailable}
      result -> result
    end
  rescue
    _ -> {:error, :maintenance_unavailable}
  catch
    _, _ -> {:error, :maintenance_unavailable}
  end
end
