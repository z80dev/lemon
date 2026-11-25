defmodule CodingAgent.Session.JournalErasure do
  @moduledoc false

  alias CodingAgent.{Config, SessionMaintenance, SessionManager}
  alias CodingAgent.Session.Ownership
  alias LemonCore.ConfinedFS, as: FS

  @header_bytes 65_536
  @journal_name ~r/\A(.+\.jsonl)(?:\.deleting-(?:([0-9a-f]{64})-)?[A-Za-z0-9_-]{12}|\.tmp\.[0-9a-f]{12})?\z/

  def snapshot(session_key, ids, owners) do
    digest = session_digest(session_key)
    names = MapSet.new(ids, &basename/1)

    with_root(
      fn fs ->
        with {:ok, entries} <- FS.list(fs, :root) do
          entries
          |> Enum.filter(fn {_name, stat} -> stat.type == :directory end)
          |> collect(fn {bucket, _} ->
            with {:ok, live} <- scan(fs, [bucket], session_key, digest, names, owners),
                 {:ok, archive} <-
                   scan(fs, [bucket, "archive"], session_key, digest, names, owners) do
              {:ok, live ++ archive}
            end
          end)
          |> case do
            {:ok, buckets} ->
              {foreign, entries} =
                buckets |> Enum.concat() |> Enum.split_with(&match?({:foreign, _}, &1))

              {:ok, %{entries: entries, foreign_ids: MapSet.new(foreign, &elem(&1, 1))}}

            error ->
              error
          end
        end
      end,
      {:ok, %{entries: [], foreign_ids: MapSet.new()}}
    )
  end

  def verify(session_key, ids, owners, entries) do
    staged = MapSet.new(entries, &{&1.parts, &1.staged})

    with {:ok, %{entries: remaining}} <- snapshot(session_key, ids, owners),
         true <- Enum.all?(remaining, &MapSet.member?(staged, {&1.parts, &1.name})) do
      :ok
    else
      _ -> {:error, :journal_remains}
    end
  end

  def stage(entries), do: mutate(entries, &stage_one/3)
  def restore(entries), do: mutate(entries, &restore_one/3)
  def commit(entries), do: mutate(entries, &remove_one/3)

  defp scan(fs, parts, session_key, digest, names, owners) do
    in_dir(
      fs,
      parts,
      fn dir ->
        with {:ok, entries} <- FS.list(fs, dir) do
          Enum.reduce_while(entries, {:ok, []}, fn {name, stat}, {:ok, acc} ->
            case Regex.run(@journal_name, name, capture: :all_but_first) do
              [base | tag] when stat.type == :regular ->
                case candidate(fs, dir, name, stat, base, tag, session_key, digest, names, owners) do
                  {:ok, id} ->
                    staged = if name == base, do: staged_name(base, digest), else: name
                    entry = %{parts: parts, id: id, name: name, staged: staged, stat: stat}
                    {:cont, {:ok, [entry | acc]}}

                  {:foreign, _id} = foreign ->
                    {:cont, {:ok, [foreign | acc]}}

                  :skip ->
                    {:cont, {:ok, acc}}

                  {:error, _} = error ->
                    {:halt, error}
                end

              _ ->
                {:cont, {:ok, acc}}
            end
          end)
        end
      end,
      {:ok, []}
    )
  end

  defp candidate(fs, dir, name, stat, base, tag, key, digest, names, owners) do
    known? = tag == [digest] or MapSet.member?(names, base)

    if tag == [] or tag == [digest] do
      read_candidate(fs, dir, name, stat, base, key, known?, owners)
    else
      :skip
    end
  end

  defp read_candidate(fs, dir, name, stat, base, key, known?, owners) do
    with {:ok, bytes, _} <- FS.read(fs, dir, name, @header_bytes, expect: stat, prefix: true),
         [line | _] <- :binary.split(bytes, "\n"),
         {:ok, %{"type" => "session", "id" => id} = header} when is_binary(id) <-
           Jason.decode(line),
         true <- basename(id) == base do
      binding = Map.get(owners, {"lemon", id})
      owner = header["sessionKey"]

      cond do
        binding not in [nil, key] or owner not in [nil, key] ->
          if known?, do: {:foreign, id}, else: :skip

        binding == key or owner == key or known? ->
          {:ok, id}

        true ->
          :skip
      end
    else
      _ when known? -> {:error, :journal_unreadable}
      _ -> :skip
    end
  end

  defp mutate([], _fun), do: :ok

  defp mutate(entries, fun) do
    SessionMaintenance.with_root_lock(fn ->
      with_root(
        fn fs ->
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            path = Path.join([root() | entry.parts] ++ [entry.name])

            result =
              Ownership.with_file(path, fn ->
                in_dir(
                  fs,
                  entry.parts,
                  &fun.(fs, &1, entry),
                  {:error, :journal_directory_missing}
                )
              end)

            if result == :ok, do: {:cont, :ok}, else: {:halt, result}
          end)
        end,
        {:error, :journal_directory_missing}
      )
    end)
  end

  defp stage_one(_fs, _dir, %{name: name, staged: name}), do: :ok

  defp stage_one(fs, dir, entry) do
    path = Path.join([root() | entry.parts] ++ [entry.name])

    with nil <- Ownership.owner(path),
         {:ok, stat} <- FS.stat(fs, dir, entry.name),
         true <- same_file?(stat, entry.stat) do
      FS.rename(fs, dir, entry.name, dir, entry.staged, no_replace: true)
    else
      _ -> {:error, :journal_changed_or_in_use}
    end
  end

  defp restore_one(_fs, _dir, %{name: name, staged: name}), do: :ok

  defp restore_one(fs, dir, entry) do
    case FS.stat(fs, dir, entry.staged) do
      {:error, :enoent} ->
        :ok

      {:ok, stat} ->
        if same_file?(stat, entry.stat),
          do: FS.rename(fs, dir, entry.staged, dir, entry.name, no_replace: true),
          else: {:error, :journal_restore_conflict}

      error ->
        error
    end
  end

  defp remove_one(fs, dir, entry) do
    case FS.unlink(fs, dir, entry.staged, expect: entry.stat) do
      :ok ->
        case FS.stat(fs, dir, entry.staged) do
          {:error, :enoent} -> :ok
          _ -> {:error, :journal_remains}
        end

      {:error, :enoent} ->
        :ok

      error ->
        error
    end
  end

  defp same_file?(%{type: :regular, dev: dev, inode: inode}, %{dev: dev, inode: inode}), do: true
  defp same_file?(_, _), do: false

  defp with_root(fun, missing) do
    case FS.with_root(root(), fun) do
      {:error, :enoent} -> missing
      result -> result
    end
  end

  defp in_dir(fs, parts, fun, missing) do
    case FS.open_dir(fs, :root, parts) do
      {:ok, dir} ->
        try do
          fun.(dir)
        after
          FS.close_dir(fs, dir)
        end

      {:error, :enoent} ->
        missing

      error ->
        error
    end
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, entries} -> {:cont, {:ok, [entries | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp root, do: Path.expand(Path.join(Config.agent_dir(), "sessions"))
  defp basename(id), do: Path.basename(SessionManager.session_file_path(root(), id))
  defp session_digest(key), do: Base.encode16(:crypto.hash(:sha256, key), case: :lower)

  defp staged_name(base, digest),
    do:
      base <>
        ".deleting-" <>
        digest <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
