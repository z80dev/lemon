defmodule LemonOmp.SessionFiles do
  @moduledoc """
  Read-only discovery of omp's on-disk sessions for a workspace.

  omp stores each session as `<agent_dir>/sessions/<encoded cwd>/<timestamp>_<uuid>.jsonl`.
  The first physical line is a fixed-width title slot
  (`{"type":"title","v":1,"title":...}`), the second the session header
  (`{"type":"session","id":...,"cwd":...}`), then tree-linked entries. A clean
  shutdown appends a `custom` entry with `customType: "session_exit"`.

  The directory name encodes the canonical cwd: home-relative paths become
  `-<rel with / replaced by ->`, temp-relative paths `-tmp-<rel>`, and anything
  else `--<abs path without leading slash>--`. Because omp's own rules depend
  on its notion of the temp root, discovery checks every candidate name and
  then trusts only headers whose `cwd` resolves to the requested workspace.

  Each file is read in bounded slices — its head for identity and title, its
  tail for the latest model and outcome — never in full, and only the newest
  files are examined. Nothing here writes, locks or migrates omp state.
  """

  @head_bytes 16_384
  @tail_bytes 65_536
  @default_limit 20
  @max_limit 100
  @active_window_ms 120_000

  @spec discover(String.t(), keyword()) :: {:ok, [map()]} | {:error, :invalid_cwd}
  def discover(cwd, opts \\ []) do
    with {:ok, sessions} <- discover_workspace(cwd, opts) do
      workers =
        LemonOmp.Worktree.kept(cwd)
        |> Enum.flat_map(fn worktree ->
          case discover_workspace(worktree.path, opts) do
            {:ok, entries} ->
              Enum.map(entries, &Map.put(&1, "worktree", LemonOmp.Worktree.wire(worktree)))

            _ ->
              []
          end
        end)

      limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

      {:ok,
       (workers ++ sessions)
       |> Enum.uniq_by(& &1["ompSessionId"])
       |> Enum.sort_by(&(-&1["updatedAt"]))
       |> Enum.take(limit)}
    end
  end

  defp discover_workspace(cwd, opts) when is_binary(cwd) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    sessions_dir = Keyword.get_lazy(opts, :sessions_dir, &LemonOmp.Config.sessions_dir/0)
    expanded = Path.expand(cwd)

    if File.dir?(expanded) do
      canonical = canonical_path(expanded)

      sessions =
        canonical
        |> candidate_dir_names(expanded)
        |> Enum.map(&Path.join(sessions_dir, &1))
        |> Enum.uniq()
        |> Enum.flat_map(&session_files/1)
        |> Enum.sort_by(fn {_path, mtime} -> -mtime end)
        |> Enum.take(limit * 2)
        |> Enum.flat_map(fn {path, mtime} -> read_session(path, mtime, canonical) end)
        |> Enum.take(limit)

      {:ok, sessions}
    else
      {:error, :invalid_cwd}
    end
  end

  @doc false
  @spec candidate_dir_names(String.t(), String.t()) :: [String.t()]
  def candidate_dir_names(canonical, expanded) do
    home = canonical_path(System.user_home!())

    temp_roots =
      [System.tmp_dir!(), "/tmp"]
      |> Enum.map(&canonical_path/1)
      |> Enum.uniq()

    [canonical, expanded]
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      relative_names(path, home, "-") ++
        Enum.flat_map(temp_roots, &relative_names(path, &1, "-tmp")) ++
        [absolute_name(path)]
    end)
    |> Enum.uniq()
  end

  defp relative_names(path, root, prefix) do
    cond do
      path == root ->
        [prefix]

      String.starts_with?(path, root <> "/") ->
        relative = String.replace_prefix(path, root <> "/", "")
        encoded = String.replace(relative, ["/", "\\", ":"], "-")

        [
          if(String.ends_with?(prefix, "-"),
            do: prefix <> encoded,
            else: prefix <> "-" <> encoded
          )
        ]

      true ->
        []
    end
  end

  defp absolute_name(path) do
    "--" <>
      (path |> String.replace_prefix("/", "") |> String.replace(["/", "\\", ":"], "-")) <> "--"
  end

  defp session_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.take(2_000)
        |> Enum.flat_map(fn name ->
          path = Path.join(dir, name)

          case File.stat(path, time: :posix) do
            {:ok, %{type: :regular, mtime: mtime}} -> [{path, mtime * 1000}]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp read_session(path, mtime_ms, canonical_cwd) do
    with {:ok, io} <- File.open(path, [:read, :binary]),
         {:ok, %{size: size}} <- File.stat(path) do
      head = pread(io, 0, @head_bytes)
      tail_offset = max(size - @tail_bytes, 0)
      # Files between the head and tail budgets need their own tail read: the
      # head slice stops short of their latest entries.
      tail = if size <= @head_bytes, do: head, else: pread(io, tail_offset, @tail_bytes)
      File.close(io)

      head_entries = decode_lines(head, drop_partial_last: size > @head_bytes)
      tail_entries = decode_lines(tail, drop_partial_first: tail_offset > 0)

      case Enum.find(head_entries, &(&1["type"] == "session")) do
        %{"id" => id, "cwd" => cwd} when is_binary(id) and is_binary(cwd) ->
          if canonical_path(cwd) == canonical_cwd do
            [project(id, cwd, head_entries, tail_entries, mtime_ms)]
          else
            []
          end

        _ ->
          []
      end
    else
      _ -> []
    end
  end

  defp project(id, cwd, head_entries, tail_entries, mtime_ms) do
    header = Enum.find(head_entries, &(&1["type"] == "session"))
    slot = Enum.find(head_entries, &(&1["type"] == "title"))
    entries = if tail_entries == [], do: head_entries, else: tail_entries
    last = List.last(entries)

    %{
      "ompSessionId" => LemonOmp.Projection.clean(id, 128),
      "title" => title(slot, header, head_entries),
      "cwd" => cwd,
      "createdAt" => parse_ms(header["timestamp"]),
      "updatedAt" => mtime_ms,
      "model" => latest_model(head_entries ++ tail_entries),
      "lastStatus" => last_status(entries, last),
      "interrupted" => last_status(entries, last) == "interrupted",
      "activeElsewhere" => active_elsewhere?(last, mtime_ms),
      "liveId" => nil
    }
  end

  defp title(slot, header, entries) do
    [slot && slot["title"], header["title"], first_user_text(entries)]
    |> Enum.find_value(fn
      value when is_binary(value) ->
        case LemonOmp.Projection.title_from_prompt(value) do
          nil -> nil
          title -> title
        end

      _ ->
        nil
    end)
  end

  defp first_user_text(entries) do
    Enum.find_value(entries, fn
      %{"type" => "message", "message" => %{"role" => "user", "content" => content}} ->
        text_of(content)

      _ ->
        nil
    end)
  end

  defp text_of(content) when is_binary(content), do: content

  defp text_of(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp text_of(_content), do: nil

  defp latest_model(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "model_change", "model" => model} when is_binary(model) ->
        LemonOmp.Projection.clean(model, 128)

      %{"type" => "message", "message" => %{"role" => "assistant", "provider" => p, "model" => m}}
      when is_binary(p) and is_binary(m) ->
        LemonOmp.Projection.clean("#{p}/#{m}", 128)

      _ ->
        nil
    end)
  end

  defp last_status(entries, last) do
    exited? = match?(%{"type" => "custom", "customType" => "session_exit"}, last)

    last_message =
      entries
      |> Enum.reverse()
      |> Enum.find(&(&1["type"] == "message"))

    case last_message do
      nil ->
        if exited?, do: "empty", else: "unknown"

      %{"message" => %{"role" => "assistant", "stopReason" => reason}} ->
        case reason do
          "stop" -> "completed"
          "error" -> "error"
          "aborted" -> "aborted"
          _ -> if exited?, do: "exited", else: "interrupted"
        end

      %{"message" => %{"role" => role}} when role in ["user", "toolResult"] ->
        if exited?, do: "exited", else: "interrupted"

      _ ->
        "unknown"
    end
  end

  # A file still being appended to without a clean-exit marker is probably an
  # omp running outside Lemon. This is a hint for the operator, not a lock.
  defp active_elsewhere?(last, mtime_ms) do
    not match?(%{"type" => "custom", "customType" => "session_exit"}, last) and
      System.system_time(:millisecond) - mtime_ms < @active_window_ms
  end

  defp decode_lines(data, opts) do
    lines = String.split(data, "\n")
    lines = if opts[:drop_partial_first], do: Enum.drop(lines, 1), else: lines
    lines = if opts[:drop_partial_last], do: Enum.drop(lines, -1), else: lines

    Enum.flat_map(lines, fn line ->
      case Jason.decode(line) do
        {:ok, %{} = entry} -> [entry]
        _ -> []
      end
    end)
  end

  defp pread(io, offset, bytes) do
    case :file.pread(io, offset, bytes) do
      {:ok, data} -> data
      _ -> ""
    end
  end

  defp parse_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> nil
    end
  end

  defp parse_ms(_value), do: nil

  defp canonical_path(path) do
    expanded = Path.expand(path)

    case resolve_links(expanded) do
      {:ok, resolved} -> resolved
      :error -> expanded
    end
  end

  # Resolve symlinks component by component (e.g. macOS /tmp -> /private/tmp),
  # mirroring omp's canonical-cwd classification.
  defp resolve_links(path) do
    path
    |> Path.split()
    |> Enum.reduce_while({:ok, "/", 0}, fn
      "/", acc ->
        {:cont, acc}

      part, {:ok, base, depth} ->
        candidate = Path.join(base, part)

        case File.read_link(candidate) do
          {:ok, target} when depth < 32 ->
            target = Path.expand(target, base)

            case resolve_links(target) do
              {:ok, resolved} -> {:cont, {:ok, resolved, depth + 1}}
              :error -> {:halt, :error}
            end

          {:ok, _target} ->
            {:halt, :error}

          {:error, _} ->
            {:cont, {:ok, candidate, depth}}
        end
    end)
    |> case do
      {:ok, resolved, _depth} -> {:ok, resolved}
      :error -> :error
    end
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_limit), do: @default_limit
end
