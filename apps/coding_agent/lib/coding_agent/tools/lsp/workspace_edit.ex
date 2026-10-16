defmodule CodingAgent.Tools.Lsp.WorkspaceEdit do
  @moduledoc """
  Plan, preview and apply LSP `WorkspaceEdit`s for the `lsp` tool.

  `documentChanges` run in declared order: text edits for a document are
  accumulated and flushed before any create/rename/delete that touches the
  same path or a directory containing it, as in the LSP specification. The
  legacy `changes` map becomes one text operation per file.

  Applying follows the coding-tool mutation conventions: every affected path
  is locked through `CodingAgent.MutationLock`, targets are validated with
  `FileValidation.check_mutation_target/2`, a filesystem checkpoint is taken
  before the first write, text edits for untouched files are computed (and
  thereby validated) before anything is written, files are replaced atomically
  through a sibling temp file, and `FileReadTracker` is refreshed afterwards.
  """

  alias CodingAgent.FileReadTracker
  alias CodingAgent.MutationLock
  alias CodingAgent.Tools.{CheckpointGuard, FileValidation}
  alias CodingAgent.Tools.Lsp.Text
  alias LemonAgent.Tools.AbortHelpers

  @type op ::
          %{kind: :text, path: String.t(), edits: [map()]}
          | %{kind: :create, path: String.t(), options: map()}
          | %{kind: :rename, from: String.t(), to: String.t(), options: map()}
          | %{kind: :delete, path: String.t(), options: map()}

  @doc "Flatten a `WorkspaceEdit` into ordered operations."
  @spec plan(map() | nil) :: {:ok, [op()]} | {:error, String.t()}
  def plan(%{"documentChanges" => changes}) when is_list(changes) do
    changes
    |> Enum.reduce_while({:ok, [], []}, fn change, {:ok, ops, pending} ->
      case plan_change(change, ops, pending) do
        {:ok, ops, pending} -> {:cont, {:ok, ops, pending}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ops, pending} -> {:ok, Enum.reverse(flush(ops, pending, fn _ -> true end))}
      error -> error
    end
  end

  def plan(%{"changes" => changes}) when is_map(changes) do
    changes
    |> Enum.sort_by(fn {uri, _edits} -> uri end)
    |> Enum.reduce_while({:ok, []}, fn {uri, edits}, {:ok, ops} ->
      with {:ok, path} <- path(uri),
           {:ok, edits} <- text_edits(edits) do
        {:cont, {:ok, if(edits == [], do: ops, else: [text_op(path, edits) | ops])}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      error -> error
    end
  end

  def plan(nil), do: {:ok, []}
  def plan(edit) when is_map(edit), do: {:ok, []}
  def plan(_edit), do: {:error, "Malformed workspace edit"}

  defp plan_change(
         %{"textDocument" => %{"uri" => uri} = document, "edits" => edits},
         ops,
         pending
       ) do
    with {:ok, path} <- path(uri),
         {:ok, edits} <- text_edits(edits) do
      version = document["version"]

      case List.keyfind(pending, path, 0) do
        nil ->
          {:ok, ops, pending ++ [{path, %{edits: edits, version: version}}]}

        {^path, %{version: ^version} = existing} ->
          updated = %{existing | edits: existing.edits ++ edits}
          {:ok, ops, List.keyreplace(pending, path, 0, {path, updated})}

        _ ->
          {:error, "Conflicting document versions in workspace edit: #{path}"}
      end
    end
  end

  defp plan_change(%{"kind" => "create", "uri" => uri} = change, ops, pending) do
    with {:ok, path} <- path(uri) do
      ops = flush(ops, pending, &(&1 == path))
      pending = Enum.reject(pending, fn {p, _} -> p == path end)
      {:ok, [%{kind: :create, path: path, options: options(change)} | ops], pending}
    end
  end

  defp plan_change(%{"kind" => "rename", "oldUri" => old, "newUri" => new} = change, ops, pending) do
    with {:ok, from} <- path(old),
         {:ok, to} <- path(new) do
      touched? = &(within?(&1, from) or within?(&1, to))
      ops = flush(ops, pending, touched?)
      pending = Enum.reject(pending, fn {p, _} -> touched?.(p) end)
      {:ok, [%{kind: :rename, from: from, to: to, options: options(change)} | ops], pending}
    end
  end

  defp plan_change(%{"kind" => "delete", "uri" => uri} = change, ops, pending) do
    with {:ok, path} <- path(uri) do
      ops = flush(ops, pending, &within?(&1, path))
      pending = Enum.reject(pending, fn {p, _} -> within?(p, path) end)
      {:ok, [%{kind: :delete, path: path, options: options(change)} | ops], pending}
    end
  end

  defp plan_change(change, _ops, _pending),
    do: {:error, "Unsupported workspace edit change: #{inspect(change, limit: 5)}"}

  defp flush(ops, pending, select?) do
    Enum.reduce(pending, ops, fn {path, %{edits: edits, version: version}}, ops ->
      if select?.(path) and edits != [], do: [text_op(path, edits, version) | ops], else: ops
    end)
  end

  defp text_op(path, edits, version \\ nil),
    do: %{kind: :text, path: path, edits: edits, version: version}

  defp text_edits(edits) when is_list(edits) do
    # AnnotatedTextEdit is a TextEdit with an extra annotationId.
    {:ok, Enum.filter(edits, &(is_map(&1) and Map.has_key?(&1, "range")))}
  end

  defp text_edits(_edits), do: {:error, "Malformed text edit list"}

  defp options(change) do
    case Map.get(change, "options") do
      options when is_map(options) -> options
      _ -> %{}
    end
  end

  defp path(uri) when is_binary(uri) do
    case Text.uri_to_path(uri) do
      {:ok, path} -> {:ok, Path.expand(path)}
      :error -> {:error, "Workspace edit targets a non-file URI: #{uri}"}
    end
  end

  defp path(uri), do: {:error, "Malformed workspace edit URI: #{inspect(uri)}"}

  defp within?(path, base), do: path == base or String.starts_with?(path, base <> "/")

  @doc "Human-readable preview lines for planned operations."
  @spec describe([op()], String.t()) :: [String.t()]
  def describe(ops, cwd) do
    Enum.map(ops, fn
      %{kind: :text, path: path, edits: edits} ->
        lines =
          edits
          |> Enum.flat_map(fn edit ->
            case get_in(edit, ["range", "start", "line"]) do
              line when is_integer(line) -> [line + 1]
              _ -> []
            end
          end)
          |> Enum.uniq()
          |> Enum.sort()

        shown = Enum.take(lines, 12)
        more = if length(lines) > 12, do: ", …", else: ""

        "#{Text.display_path(path, cwd)}: #{plural(length(edits), "edit")} " <>
          "(line#{if length(lines) == 1, do: "", else: "s"} #{Enum.join(shown, ", ")}#{more})"

      %{kind: :create, path: path} ->
        "CREATE: #{Text.display_path(path, cwd)}"

      %{kind: :rename, from: from, to: to} ->
        "RENAME: #{Text.display_path(from, cwd)} → #{Text.display_path(to, cwd)}"

      %{kind: :delete, path: path} ->
        "DELETE: #{Text.display_path(path, cwd)}"
    end)
  end

  @doc "Every filesystem path the operations may change."
  @spec affected_paths([op()]) :: [String.t()]
  def affected_paths(ops) do
    ops
    |> Enum.flat_map(fn
      %{kind: :rename, from: from, to: to} -> [from, to]
      %{path: path} -> [path]
    end)
    |> Enum.uniq()
  end

  @doc """
  Apply planned operations to disk.

  Returns changed paths, summary lines and checkpoint on success or a mid-way
  failure. The error receipt retains the preimage of every planned target and
  lists paths written before the failure, including created parent directories,
  leftover temp files, files created before a failed write and partially deleted
  trees. Created parents and partially deleted trees are reported by their root.
  """
  @spec apply([op()], String.t(), keyword(), reference() | nil, map()) ::
          {:ok, %{changed: [String.t()], applied: [String.t()], checkpoint: map() | nil}}
          | {:error, String.t()}
          | {:error, String.t(),
             %{changed: [String.t()], applied: [String.t()], checkpoint: map() | nil}}
  def apply([], _cwd, _opts, _signal, _meta),
    do: {:ok, %{changed: [], applied: [], checkpoint: nil}}

  def apply(ops, cwd, opts, signal, meta) do
    paths = affected_paths(ops)

    MutationLock.with_locks(Enum.map(paths, &MutationLock.path_key/1), fn ->
      with :ok <- check_deadline(opts),
           :ok <- validate_targets(ops, cwd, opts),
           :ok <- validate_versions(ops, opts),
           {:ok, prepared} <- prepare(ops, opts),
           {:ok, checkpoint} <- CheckpointGuard.before_mutation(paths, cwd, opts, meta),
           :ok <- notify_checkpoint(checkpoint, opts) do
        case commit(prepared, cwd, signal, opts) do
          {:ok, changed, applied} ->
            FileReadTracker.refresh(opts, paths)
            {:ok, %{changed: changed, applied: applied, checkpoint: checkpoint}}

          {:error, reason, changed, applied} ->
            FileReadTracker.refresh(opts, paths)

            if is_nil(checkpoint) and changed == [],
              do: {:error, reason},
              else:
                {:error, reason, %{changed: changed, applied: applied, checkpoint: checkpoint}}
        end
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, "Cannot apply workspace edit: #{inspect(reason)}"}
      end
    end)
  end

  defp check_deadline(opts) do
    case Keyword.get(opts, :mutation_deadline) do
      deadline when is_integer(deadline) ->
        if System.monotonic_time(:millisecond) < deadline,
          do: :ok,
          else: {:error, "Workspace edit request expired"}

      _ ->
        :ok
    end
  end

  defp notify_checkpoint(checkpoint, opts) do
    if callback = Keyword.get(opts, :on_checkpoint), do: callback.(checkpoint)
    :ok
  end

  defp validate_versions(ops, opts) do
    documents = Keyword.get(opts, :lsp_documents, %{})

    Enum.reduce_while(ops, :ok, fn
      %{kind: :text, path: path, version: version}, :ok when not is_nil(version) ->
        case Map.get(documents, path) do
          %{version: ^version} -> {:cont, :ok}
          _ -> {:halt, {:error, "Stale or unknown document version: #{path}"}}
        end

      _, :ok ->
        {:cont, :ok}
    end)
  end

  defp check_original(content, path, opts) do
    case opts |> Keyword.get(:lsp_documents, %{}) |> Map.get(path) do
      %{digest: digest} ->
        if :erlang.md5(content) == digest,
          do: :ok,
          else: {:error, "File changed since the language server synchronized it: #{path}"}

      _ ->
        FileReadTracker.check(opts, path, content)
    end
  end

  defp validate_targets(ops, cwd, opts) do
    mutation_opts =
      opts |> Keyword.put(:mutation_root, cwd) |> Keyword.put(:allow_directories, true)

    ops
    |> Enum.flat_map(fn
      %{kind: :rename, from: from, to: to} -> [from, to]
      %{path: path} -> [path]
    end)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case FileValidation.check_mutation_target(path, mutation_opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Text edits for files no earlier resource operation touches are computed
  # now, so malformed or overlapping edits fail before any write.
  defp prepare(ops, opts) do
    ops
    |> Enum.reduce_while({:ok, [], []}, fn op, {:ok, acc, touched} ->
      case prepare_op(op, touched, opts) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc], touched ++ touched_by(op)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared, _touched} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp prepare_op(%{kind: :text, path: path, edits: edits} = op, touched, opts) do
    if Enum.any?(touched, &within?(path, &1)) do
      {:ok, op}
    else
      with {:ok, original} <- read(path),
           :ok <- check_original(original, path, opts),
           {:ok, content} <- edited(original, edits, path) do
        {:ok, Map.merge(op, %{original: original, content: content})}
      end
    end
  end

  defp prepare_op(op, _touched, _opts), do: {:ok, op}

  defp touched_by(%{kind: :text}), do: []
  defp touched_by(%{kind: :rename, from: from, to: to}), do: [from, to]
  defp touched_by(%{path: path}), do: [path]

  defp commit(prepared, cwd, signal, opts) do
    Enum.reduce_while(prepared, {:ok, [], []}, fn op, {:ok, changed, applied} ->
      result =
        with :ok <- check_deadline(opts) do
          if AbortHelpers.aborted?(signal),
            do: {:error, "Operation aborted"},
            else: commit_op(op, cwd)
        end

      case result do
        {:ok, paths, line} ->
          {:cont, {:ok, changed ++ paths, applied ++ List.wrap(line)}}

        {:error, reason} ->
          {:halt, {:error, partial_error(reason, changed), changed, applied}}

        {:error, reason, written} ->
          changed = changed ++ written
          {:halt, {:error, partial_error(reason, changed), changed, applied}}
      end
    end)
  end

  defp commit_op(%{kind: :text, path: path, original: original, content: content} = op, cwd) do
    case read(path) do
      {:ok, ^original} ->
        with {:ok, created} <- atomic_write(path, content) do
          {:ok, created ++ [path],
           "Applied #{plural(length(op.edits), "edit")} to #{Text.display_path(path, cwd)}"}
        end

      {:ok, _changed} ->
        {:error, "File changed while applying the edit: #{path}"}

      error ->
        error
    end
  end

  defp commit_op(%{kind: :text, path: path, edits: edits}, cwd) do
    with {:ok, original} <- read(path),
         {:ok, content} <- edited(original, edits, path),
         {:ok, created} <- atomic_write(path, content) do
      {:ok, created ++ [path],
       "Applied #{plural(length(edits), "edit")} to #{Text.display_path(path, cwd)}"}
    end
  end

  defp commit_op(%{kind: :create, path: path, options: options}, cwd) do
    exists? = match?({:ok, _}, File.lstat(path))

    cond do
      exists? and options["overwrite"] == true ->
        with {:ok, created} <- atomic_write(path, ""),
             do: {:ok, created ++ [path], "Created #{Text.display_path(path, cwd)} (overwrote)"}

      exists? and options["ignoreIfExists"] == true ->
        {:ok, [], nil}

      exists? ->
        {:error, "Cannot create #{path}: it already exists"}

      true ->
        with {:ok, created} <- mkdir_parent(path) do
          case File.write(path, "", [:exclusive]) do
            :ok ->
              {:ok, created ++ [path], "Created #{Text.display_path(path, cwd)}"}

            # Without :eexist the exclusive open succeeded, so a remaining file is ours.
            {:error, reason} ->
              left =
                if reason != :eexist and match?({:ok, _}, File.lstat(path)), do: [path], else: []

              {:error, fs_message(reason, path), created ++ left}
          end
        end
    end
  end

  defp commit_op(%{kind: :rename, from: from, to: to, options: options}, cwd) do
    target_exists? = from != to and match?({:ok, _}, File.lstat(to))

    cond do
      target_exists? and options["overwrite"] != true and options["ignoreIfExists"] == true ->
        {:ok, [], nil}

      target_exists? and options["overwrite"] != true ->
        {:error, "Cannot rename #{from} to #{to}: the target already exists"}

      target_exists? and File.dir?(to) ->
        {:error, "Cannot rename #{from} over existing directory #{to}"}

      true ->
        with {:ok, created} <- mkdir_parent(to) do
          case fs(File.rename(from, to), from) do
            :ok ->
              {:ok, created ++ [from, to],
               "Renamed #{Text.display_path(from, cwd)} → #{Text.display_path(to, cwd)}"}

            {:error, reason} ->
              {:error, reason, created}
          end
        end
    end
  end

  defp commit_op(%{kind: :delete, path: path, options: options}, cwd) do
    case File.lstat(path) do
      {:error, :enoent} ->
        if options["ignoreIfNotExists"] == true,
          do: {:ok, [], nil},
          else: {:error, "Cannot delete #{path}: it does not exist"}

      {:ok, %File.Stat{type: :directory}} ->
        result =
          if options["recursive"] == true,
            do: rm_rf(path),
            else: fs(File.rmdir(path), path)

        with :ok <- result, do: {:ok, [path], "Deleted #{Text.display_path(path, cwd)}"}

      {:ok, _stat} ->
        with :ok <- fs(File.rm(path), path),
             do: {:ok, [path], "Deleted #{Text.display_path(path, cwd)}"}

      {:error, reason} ->
        fs({:error, reason}, path)
    end
  end

  # A failed recursive delete may already have removed part of the tree.
  defp rm_rf(path) do
    before = tree_fingerprint(path)

    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, reason, file} ->
        unchanged? = before != :unknown and tree_fingerprint(path) == before
        {:error, fs_message(reason, file), if(unchanged?, do: [], else: [path])}
    end
  end

  defp tree_fingerprint(path) do
    case LemonCore.Checkpoint.filesystem_fingerprint(path) do
      {:ok, fingerprint} -> fingerprint
      {:error, _} -> :unknown
    end
  end

  defp edited(original, edits, path) do
    case Text.apply_edits(original, edits) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "#{reason} (#{path})"}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      error -> fs(error, path)
    end
  end

  # Replace `path` through a sibling temp file so readers never observe a
  # partially written file. The original file mode is preserved. Returns the
  # parent directory this created, or every path left behind on failure.
  defp atomic_write(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.lemon-lsp-#{System.unique_integer([:positive])}.tmp"
      )

    mode =
      case File.stat(path) do
        {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o7777)
        _ -> nil
      end

    with {:ok, created} <- mkdir_parent(path) do
      with :ok <- fs(File.write(tmp, content, [:exclusive]), tmp),
           :ok <- if(mode, do: fs(File.chmod(tmp, mode), tmp), else: :ok),
           :ok <- fs(File.rename(tmp, path), path) do
        {:ok, created}
      else
        {:error, reason} ->
          left = if File.rm(tmp) in [:ok, {:error, :enoent}], do: [], else: [tmp]
          {:error, reason, created ++ left}
      end
    end
  end

  # Creates missing parents and reports the topmost directory it created.
  defp mkdir_parent(path) do
    dir = Path.dirname(path)
    missing = missing_ancestor(dir)

    case File.mkdir_p(dir) do
      :ok ->
        {:ok, List.wrap(missing)}

      {:error, reason} ->
        created = if missing && match?({:ok, _}, File.lstat(missing)), do: [missing], else: []
        {:error, fs_message(reason, dir), created}
    end
  end

  defp missing_ancestor(dir) do
    case File.lstat(dir) do
      {:ok, _} ->
        nil

      {:error, _} ->
        parent = Path.dirname(dir)
        if parent == dir, do: dir, else: missing_ancestor(parent) || dir
    end
  end

  defp fs(:ok, _path), do: :ok
  defp fs({:error, reason}, path), do: {:error, fs_message(reason, path)}

  defp fs_message(reason, path), do: FileValidation.format_file_error(reason, path, "file")

  defp partial_error(reason, []), do: reason

  defp partial_error(reason, changed) do
    "#{reason}; #{length(changed)} path(s) were already changed: #{Enum.join(Enum.uniq(changed), ", ")}"
  end

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"
end
