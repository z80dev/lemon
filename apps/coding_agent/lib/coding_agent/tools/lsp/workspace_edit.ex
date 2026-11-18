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
  before the first write, and text edits for untouched files are computed (and
  thereby validated) before anything is written.

  Every read, write, create, rename and delete then runs descriptor-bound
  below the boundary the validation used (`LemonCore.ConfinedFS`, through the
  `FileValidation` identity helpers where they apply), so a directory swapped
  for a symlink after validation is refused instead of followed; symlinks are
  refused even with `allow_symlinks: true`. Text files are pinned when read
  and replaced atomically with their mode kept; missing parents are created
  one directory at a time; a rename must stay below one trusted directory
  (the workspace) and a recursive delete never follows symlinks. The session's
  `FileReadTracker` records the bytes committed and forgets deleted and
  renamed-away paths.
  """

  alias CodingAgent.FileReadTracker
  alias CodingAgent.MutationLock
  alias CodingAgent.Tools.{CheckpointGuard, FileValidation}
  alias CodingAgent.Tools.Lsp.Text
  alias LemonAgent.Tools.AbortHelpers
  alias LemonCore.ConfinedFS

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
  files created before a failed write and partially deleted trees. Created
  parents and partially deleted trees are reported by their root.
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
    io_opts = opts |> Keyword.put(:mutation_root, cwd) |> Keyword.put(:allow_symlinks, false)

    MutationLock.with_locks(Enum.map(paths, &MutationLock.path_key/1), fn ->
      with :ok <- check_deadline(opts),
           :ok <- validate_targets(ops, cwd, opts),
           :ok <- validate_versions(ops, opts),
           {:ok, prepared} <- prepare(ops, io_opts),
           {:ok, checkpoint} <- CheckpointGuard.before_mutation(paths, cwd, opts, meta),
           :ok <- notify_checkpoint(checkpoint, opts) do
        case commit(prepared, cwd, signal, io_opts) do
          {:ok, changed, applied} ->
            {:ok, %{changed: changed, applied: applied, checkpoint: checkpoint}}

          {:error, reason, changed, applied} ->
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
      with {:ok, identity, original} <- read(path, opts),
           :ok <- check_original(original, path, opts),
           {:ok, content} <- edited(original, edits, path) do
        {:ok, Map.merge(op, %{identity: identity, original: original, content: content})}
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
            else: commit_op(op, cwd, opts)
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

  defp commit_op(
         %{kind: :text, path: path, identity: identity, original: original, content: content} =
           op,
         cwd,
         opts
       ) do
    case FileValidation.read_regular_file(path, identity) do
      {:ok, ^original} ->
        with :ok <- replace(path, identity, content, opts) do
          {:ok, [path],
           "Applied #{plural(length(op.edits), "edit")} to #{Text.display_path(path, cwd)}"}
        end

      {:ok, _changed} ->
        {:error, "File changed while applying the edit: #{path}"}

      error ->
        fs(error, path)
    end
  end

  defp commit_op(%{kind: :text, path: path, edits: edits}, cwd, opts) do
    with {:ok, identity, original} <- read(path, opts),
         {:ok, content} <- edited(original, edits, path),
         :ok <- replace(path, identity, content, opts) do
      {:ok, [path], "Applied #{plural(length(edits), "edit")} to #{Text.display_path(path, cwd)}"}
    end
  end

  defp commit_op(%{kind: :create, path: path, options: options}, cwd, opts) do
    with {:ok, existing} <-
           confined([path], opts, fn cfs, [parts] -> lookup(cfs, parts, path) end) do
      exists? = existing != nil

      cond do
        exists? and options["overwrite"] == true ->
          with {:ok, identity} <- pin(path, opts),
               :ok <- replace(path, identity, "", opts),
               do: {:ok, [path], "Created #{Text.display_path(path, cwd)} (overwrote)"}

        exists? and options["ignoreIfExists"] == true ->
          {:ok, [], nil}

        exists? ->
          {:error, "Cannot create #{path}: it already exists"}

        true ->
          confined([path], opts, fn cfs, [parts] -> create(cfs, path, parts, cwd, opts) end)
      end
    end
  end

  defp commit_op(%{kind: :rename, from: from, to: to, options: options}, cwd, opts) do
    confined([from, to], opts, fn cfs, [from_parts, to_parts] ->
      with {:ok, target} <- if(from != to, do: lookup(cfs, to_parts, to), else: {:ok, nil}) do
        target_exists? = target != nil

        cond do
          target_exists? and options["overwrite"] != true and options["ignoreIfExists"] == true ->
            {:ok, [], nil}

          target_exists? and options["overwrite"] != true ->
            {:error, "Cannot rename #{from} to #{to}: the target already exists"}

          target_exists? and target.type == :directory ->
            {:error, "Cannot rename #{from} over existing directory #{to}"}

          true ->
            rename(cfs, {from, from_parts}, {to, to_parts}, options, cwd, opts)
        end
      end
    end)
  end

  defp commit_op(%{kind: :delete, path: path, options: options}, cwd, opts) do
    confined([path], opts, fn cfs, [parts] ->
      case entry(cfs, parts) do
        {:error, :enoent} ->
          if options["ignoreIfNotExists"] == true,
            do: {:ok, [], nil},
            else: {:error, "Cannot delete #{path}: it does not exist"}

        {:ok, dir, name, %ConfinedFS.Stat{type: :directory}} ->
          result =
            if options["recursive"] == true,
              do: remove_tree(cfs, dir, name, path),
              else: fs(ConfinedFS.rmdir(cfs, dir, name), path)

          with :ok <- result, do: deleted(path, cwd, opts)

        {:ok, dir, name, stat} ->
          with :ok <- fs(ConfinedFS.unlink(cfs, dir, name, expect: stat), path),
               do: deleted(path, cwd, opts)

        {:error, reason} ->
          fs({:error, reason}, path)
      end
    end)
  end

  # Without :eexist the exclusive create succeeded, so a remaining file is ours.
  defp create(cfs, path, parts, cwd, opts) do
    case open_parent(cfs, path, parts) do
      {:ok, dir, name, created} ->
        case ConfinedFS.create(cfs, dir, name, "") do
          {:ok, _stat} ->
            FileReadTracker.record(opts, path, "")
            {:ok, created ++ [path], "Created #{Text.display_path(path, cwd)}"}

          {:error, reason} ->
            left =
              if reason != :eexist and match?({:ok, _}, ConfinedFS.stat(cfs, dir, name)),
                do: [path],
                else: []

            {:error, fs_message(reason, path), created ++ left}
        end

      {:error, reason, created} ->
        {:error, fs_message(reason, Path.dirname(path)), created}
    end
  end

  # Without explicit `overwrite` the rename never replaces a destination, even
  # one created after the existence check (`no_replace`, atomic); such a late
  # destination is then skipped under `ignoreIfExists`, as an earlier one is.
  # A rename to the same path is not a replacement.
  defp rename(cfs, {from, from_parts}, {to, to_parts}, options, cwd, opts) do
    no_replace = from != to and options["overwrite"] != true

    case open_parent(cfs, to, to_parts) do
      {:ok, to_dir, to_name, created} ->
        with {:ok, from_dir, from_name} <- ConfinedFS.open_parent(cfs, :root, from_parts),
             :ok <- before_rename(opts),
             :ok <-
               ConfinedFS.rename(cfs, from_dir, from_name, to_dir, to_name,
                 no_replace: no_replace
               ) do
          FileReadTracker.forget(opts, from)
          FileReadTracker.forget(opts, to)

          {:ok, created ++ [from, to],
           "Renamed #{Text.display_path(from, cwd)} → #{Text.display_path(to, cwd)}"}
        else
          {:error, :eexist} when no_replace ->
            if options["ignoreIfExists"] == true,
              do: {:ok, created, nil},
              else: {:error, "Cannot rename #{from} to #{to}: the target already exists", created}

          {:error, reason} ->
            {:error, fs_message(reason, from), created}
        end

      {:error, reason, created} ->
        {:error, fs_message(reason, Path.dirname(to)), created}
    end
  end

  # Test seam: `opts[:before_rename]` runs after the destination checks and
  # just before the rename, where a concurrent writer could create the target.
  defp before_rename(opts) do
    if hook = Keyword.get(opts, :before_rename), do: hook.()
    :ok
  end

  defp deleted(path, cwd, opts) do
    FileReadTracker.forget(opts, path)
    {:ok, [path], "Deleted #{Text.display_path(path, cwd)}"}
  end

  # A failed recursive delete may already have removed part of the tree.
  defp remove_tree(cfs, dir, name, path) do
    before = tree_fingerprint(path)

    case ConfinedFS.remove_tree(cfs, dir, name) do
      :ok ->
        :ok

      {:error, reason} ->
        unchanged? = before != :unknown and tree_fingerprint(path) == before
        {:error, fs_message(reason, path), if(unchanged?, do: [], else: [path])}
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

  defp pin(path, opts) do
    case FileValidation.regular_file_identity(path, opts) do
      {:ok, identity} -> {:ok, identity}
      error -> fs(error, path)
    end
  end

  # Pins the regular file and reads only that file.
  defp read(path, opts) do
    with {:ok, identity} <- pin(path, opts) do
      case FileValidation.read_regular_file(path, identity) do
        {:ok, content} -> {:ok, identity, content}
        error -> fs(error, path)
      end
    end
  end

  # Atomically replaces the pinned file, keeping its mode, through a private
  # temp file renamed over it, and records the committed bytes.
  defp replace(path, identity, content, opts) do
    with :ok <- fs(FileValidation.replace_regular_file(path, identity, content, opts), path) do
      FileReadTracker.record(opts, path, content)
    end
  end

  # Runs `fun` with the components of each path in one LemonCore.ConfinedFS
  # session rooted at the boundary check_mutation_target/2 validated them
  # below (same opts). Paths below different boundaries fail closed.
  defp confined(paths, opts, fun) do
    with {:ok, root, parts} <- locate(paths, opts) do
      case ConfinedFS.with_root(root, &fun.(&1, parts)) do
        {:error, reason} when is_atom(reason) -> fs({:error, reason}, hd(paths))
        result -> result
      end
    end
  end

  defp locate(paths, opts) do
    Enum.reduce_while(paths, {:ok, nil, []}, fn path, {:ok, root, acc} ->
      case FileValidation.mutation_location(path, opts) do
        {:ok, here, parts} when is_nil(root) or here == root ->
          {:cont, {:ok, here, acc ++ [parts]}}

        {:ok, _other, _parts} ->
          {:halt,
           {:error,
            "Workspace edit paths must be below the same trusted directory: " <>
              Enum.join(paths, ", ")}}

        error ->
          {:halt, error}
      end
    end)
  end

  # lstat of the entry `parts` names, never following a symlink on the way.
  defp entry(cfs, parts) do
    with {:ok, dir, name} <- ConfinedFS.open_parent(cfs, :root, parts),
         {:ok, stat} <- ConfinedFS.stat(cfs, dir, name) do
      {:ok, dir, name, stat}
    end
  end

  defp lookup(cfs, parts, path) do
    case entry(cfs, parts) do
      {:ok, _dir, _name, stat} -> {:ok, stat}
      {:error, :enoent} -> {:ok, nil}
      error -> fs(error, path)
    end
  end

  # Opens the parent of `parts`, creating missing directories one at a time
  # without following symlinks, and reports the topmost one it created.
  defp open_parent(cfs, path, parts) do
    {dirs, [name]} = Enum.split(parts, -1)
    root = Enum.reduce(parts, path, fn _part, at -> Path.dirname(at) end)

    dirs
    |> Enum.reduce_while({:ok, :root, root, []}, fn part, {:ok, dir, at, created} ->
      at = Path.join(at, part)

      case ConfinedFS.mkdir(cfs, dir, part) do
        result when result in [:ok, {:error, :eexist}] ->
          created = if result == :ok and created == [], do: [at], else: created

          case ConfinedFS.open_dir(cfs, dir, [part]) do
            {:ok, handle} -> {:cont, {:ok, handle, at, created}}
            {:error, reason} -> {:halt, {:error, reason, created}}
          end

        {:error, reason} ->
          {:halt, {:error, reason, created}}
      end
    end)
    |> case do
      {:ok, dir, _at, created} -> {:ok, dir, name, created}
      error -> error
    end
  end

  defp fs(:ok, _path), do: :ok
  defp fs({:error, reason}, path), do: {:error, fs_message(reason, path)}

  defp fs_message(reason, _path) when is_binary(reason), do: reason

  defp fs_message(reason, path) do
    case FileValidation.confined_error(reason, path) do
      {:error, message} when is_binary(message) -> message
      {:error, reason} -> FileValidation.format_file_error(reason, path, "file")
    end
  end

  defp partial_error(reason, []), do: reason

  defp partial_error(reason, changed) do
    "#{reason}; #{length(changed)} path(s) were already changed: #{Enum.join(Enum.uniq(changed), ", ")}"
  end

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"
end
