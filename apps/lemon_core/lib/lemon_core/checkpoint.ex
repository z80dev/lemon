defmodule LemonCore.Checkpoint do
  @moduledoc """
  Shared checkpoint store and filesystem rollback operations.

  Persisted JSON keys use existing atoms when available and remain strings
  otherwise. Freeform state and tool metadata therefore do not require their
  producer modules to be loaded, and reading checkpoints never creates atoms.

  Filesystem captures include complete directory trees (empty directories and
  modes included) and symlink targets without following links. Defaults are
  10 MiB per file, 50 MiB aggregate content, 10,000 entries and depth 128 per
  capture; `max_bytes`, `max_total_bytes`, `max_entries`, `max_depth` override
  those bounds. Unsupported or over-budget trees fail before a checkpoint is
  written. Restore validates the entire selected snapshot and parent paths before
  replacing roots; absent roots remove newly created trees, not just files.
  Customized capture limits travel with the checkpoint for restore validation;
  explicit restore options may override them. Directory owner access is granted
  temporarily during tree replacement, then recorded modes are reapplied.

  Capture and fingerprint paths must have no symlink ancestors; a captured root
  may itself be a symlink, whose identity is stored without following its target.
  Callers using an aliased workspace (such as a macOS temporary directory) must
  resolve the trusted workspace before deriving capture paths, not resolve
  model-selected paths. The default `cwd` is the physical `File.cwd!()` path.
  Restore rechecks all selected parent paths before deleting any root.
  """

  require Logger

  @checkpoint_version "1.0"

  @type checkpoint :: %{
          id: String.t(),
          session_id: String.t(),
          timestamp: String.t(),
          state: map(),
          context: map(),
          todos: list(),
          requirements: map() | nil,
          metadata: map()
        }

  @type filesystem_snapshot :: %{
          optional(:entries) => list(),
          optional(:target) => String.t(),
          optional(:size) => non_neg_integer() | nil,
          optional(:mode) => non_neg_integer() | nil,
          optional(:content_b64) => String.t() | nil,
          path: String.t(),
          exists: boolean(),
          type: String.t() | nil
        }

  @spec create(String.t(), keyword()) :: {:ok, checkpoint()} | {:error, term()}
  def create(session_id, opts \\ []) when is_binary(session_id) do
    checkpoint = %{
      id: generate_checkpoint_id(),
      session_id: session_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      state: opts[:state] || %{},
      context: opts[:context] || %{},
      todos: opts[:todos] || [],
      requirements: opts[:requirements],
      metadata: Map.merge(%{version: @checkpoint_version}, opts[:metadata] || %{})
    }

    case save_checkpoint(checkpoint) do
      :ok ->
        Logger.debug("Created checkpoint #{checkpoint.id} for session #{session_id}")

        emit_checkpoint_event(
          :checkpoint_created,
          checkpoint,
          checkpoint_created_payload(checkpoint),
          opts
        )

        {:ok, checkpoint}

      {:error, reason} ->
        Logger.error("Failed to create checkpoint: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec create_filesystem(String.t(), [String.t()], keyword()) ::
          {:ok, checkpoint()} | {:error, term()}
  def create_filesystem(session_id, paths, opts \\ [])
      when is_binary(session_id) and is_list(paths) do
    cwd = opts[:cwd] || File.cwd!()
    tool = opts[:tool] || "unknown"

    with {:ok, snapshots} <- snapshot_files(paths, cwd, opts) do
      create(session_id,
        state: %{
          filesystem: %{
            cwd: Path.expand(cwd),
            files: snapshots,
            capture_limits:
              Map.new(
                Keyword.take(opts, [
                  :max_bytes,
                  :max_total_bytes,
                  :max_entries,
                  :max_depth
                ])
              )
          }
        },
        metadata:
          Map.merge(
            %{
              kind: "filesystem",
              version: @checkpoint_version,
              tool: tool,
              path_count: length(snapshots)
            },
            opts[:metadata] || %{}
          ),
        run_id: opts[:run_id],
        session_key: opts[:session_key],
        agent_id: opts[:agent_id],
        parent_run_id: opts[:parent_run_id]
      )
    end
  end

  @doc "Bounded tree identity for preview confirmation; does not follow symlinks."
  @spec filesystem_fingerprint(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def filesystem_fingerprint(path, opts \\ []) do
    with {:ok, budget} <- snapshot_budget(opts),
         :ok <- safe_parents(Path.expand(path)),
         {:ok, node, _budget} <- snapshot_node(Path.expand(path), budget, 0, true) do
      {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(node))}
    end
  rescue
    _ -> {:error, :fingerprint_failed}
  end

  @spec diff_filesystem(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def diff_filesystem(checkpoint_id, opts \\ []) when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- load(checkpoint_id),
         {:ok, files} <- filesystem_files(checkpoint),
         {:ok, paths} <- selected_snapshot_paths(files, opts[:paths]) do
      diffs =
        files
        |> Enum.filter(&(&1.path in paths))
        |> Enum.map(&diff_snapshot/1)
        |> Enum.reject(&is_nil/1)

      {:ok,
       %{
         checkpoint_id: checkpoint.id,
         session_id: checkpoint.session_id,
         changed: Enum.map(diffs, & &1.path),
         diffs: diffs,
         output: format_filesystem_diffs(diffs)
       }}
    end
  end

  @spec restore_filesystem(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore_filesystem(checkpoint_id, opts \\ []) when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- load(checkpoint_id),
         {:ok, files} <- filesystem_files(checkpoint),
         {:ok, paths} <- selected_snapshot_paths(files, opts[:paths]),
         {:ok, validation_opts} <- restore_limits(checkpoint, opts),
         :ok <- validate_restore(Enum.filter(files, &(&1.path in paths)), validation_opts) do
      files
      |> Enum.filter(&(&1.path in paths))
      |> Enum.reduce_while({:ok, []}, fn snapshot, {:ok, restored} ->
        case restore_snapshot(snapshot) do
          :ok -> {:cont, {:ok, [snapshot.path | restored]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, restored} ->
          result = %{
            checkpoint_id: checkpoint.id,
            session_id: checkpoint.session_id,
            restored: Enum.reverse(restored)
          }

          emit_checkpoint_event(
            :checkpoint_restored,
            checkpoint,
            Map.merge(checkpoint_base_payload(checkpoint), %{
              restored: result.restored,
              restored_count: length(result.restored)
            }),
            opts
          )

          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec load(String.t()) :: {:ok, checkpoint()} | {:error, term()}
  def load(checkpoint_id) when is_binary(checkpoint_id) do
    path = checkpoint_path(checkpoint_id)

    case File.read(path) do
      {:ok, content} ->
        case decode_checkpoint(content) do
          {:ok, checkpoint} -> {:ok, checkpoint}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec list(String.t()) :: [checkpoint()]
  def list(session_id) when is_binary(session_id) do
    ensure_checkpoint_dir()

    checkpoint_dir()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(fn filename ->
      path = Path.join(checkpoint_dir(), filename)

      case File.read(path) do
        {:ok, content} ->
          case decode_checkpoint(content) do
            {:ok, checkpoint} -> checkpoint
            _ -> nil
          end

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(&1.session_id == session_id))
    |> Enum.sort_by(& &1.timestamp, :desc)
  end

  @spec get_latest(String.t()) :: {:ok, checkpoint()} | {:error, :not_found}
  def get_latest(session_id) when is_binary(session_id) do
    case list(session_id) do
      [] -> {:error, :not_found}
      [latest | _] -> {:ok, latest}
    end
  end

  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(checkpoint_id, opts \\ []) when is_binary(checkpoint_id) do
    path = checkpoint_path(checkpoint_id)
    existing = load(checkpoint_id)

    case File.rm(path) do
      :ok ->
        Logger.debug("Deleted checkpoint #{checkpoint_id}")
        maybe_emit_checkpoint_deleted(existing, opts)
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec delete_all(String.t()) :: {:ok, non_neg_integer()}
  def delete_all(session_id) when is_binary(session_id) do
    checkpoints = list(session_id)

    Enum.each(checkpoints, fn checkpoint ->
      delete(checkpoint.id)
    end)

    {:ok, length(checkpoints)}
  end

  @spec stats(String.t()) :: map()
  def stats(session_id) when is_binary(session_id) do
    checkpoints = list(session_id)

    case checkpoints do
      [] ->
        %{count: 0, filesystem_count: 0, oldest: nil, newest: nil}

      _ ->
        timestamps = Enum.map(checkpoints, & &1.timestamp)

        %{
          count: length(checkpoints),
          filesystem_count: Enum.count(checkpoints, &filesystem_checkpoint?/1),
          oldest: List.last(timestamps),
          newest: hd(timestamps)
        }
    end
  end

  @spec exists?(String.t()) :: boolean()
  def exists?(checkpoint_id) when is_binary(checkpoint_id) do
    checkpoint_path(checkpoint_id)
    |> File.exists?()
  end

  @spec prune(String.t(), non_neg_integer()) :: {:ok, non_neg_integer()}
  def prune(session_id, keep \\ 10)
      when is_binary(session_id) and is_integer(keep) and keep >= 0 do
    checkpoints = list(session_id)
    to_delete = Enum.drop(checkpoints, keep)

    Enum.each(to_delete, fn checkpoint ->
      delete(checkpoint.id)
    end)

    {:ok, length(to_delete)}
  end

  defp generate_checkpoint_id do
    "chk_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp checkpoint_path(checkpoint_id) do
    Path.join(checkpoint_dir(), "#{checkpoint_id}.json")
  end

  @doc """
  Directory checkpoints are written to; see `LemonCore.Paths.checkpoint_dir/1`.
  """
  @spec checkpoint_dir() :: String.t()
  def checkpoint_dir, do: LemonCore.Paths.checkpoint_dir()

  defp ensure_checkpoint_dir do
    File.mkdir_p!(checkpoint_dir())
  end

  defp save_checkpoint(checkpoint) do
    ensure_checkpoint_dir()
    path = checkpoint_path(checkpoint.id)

    content = Jason.encode!(checkpoint, pretty: true)
    File.write(path, content)
  end

  defp decode_checkpoint(content) do
    Jason.decode(content, keys: &checkpoint_key/1)
  end

  defp checkpoint_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp emit_checkpoint_event(event_type, checkpoint, payload, opts) do
    context = checkpoint_event_context(checkpoint, opts)

    _ =
      LemonCore.Introspection.record(event_type, payload,
        run_id: context.run_id,
        session_key: context.session_key,
        agent_id: context.agent_id,
        parent_run_id: context.parent_run_id,
        engine: "lemon",
        provenance: :direct
      )

    if LemonCore.Bus.running?() do
      event = LemonCore.Event.new(event_type, payload, context)

      if is_binary(context.run_id) do
        LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(context.run_id), event)
      end

      if is_binary(context.session_key) do
        LemonCore.Bus.broadcast(LemonCore.Bus.session_topic(context.session_key), event)
      end
    end

    :ok
  rescue
    error ->
      Logger.debug("Failed to emit checkpoint event #{event_type}: #{Exception.message(error)}")
      :ok
  end

  defp maybe_emit_checkpoint_deleted({:ok, checkpoint}, opts) do
    emit_checkpoint_event(
      :checkpoint_deleted,
      checkpoint,
      checkpoint_base_payload(checkpoint),
      opts
    )
  end

  defp maybe_emit_checkpoint_deleted(_missing, _opts), do: :ok

  defp checkpoint_created_payload(checkpoint) do
    checkpoint
    |> checkpoint_base_payload()
    |> Map.put(:created_at, checkpoint.timestamp)
  end

  defp checkpoint_base_payload(checkpoint) do
    metadata = Map.get(checkpoint, :metadata, %{})

    %{
      checkpoint_id: checkpoint.id,
      checkpoint_kind: Map.get(metadata, :kind, "session"),
      session_id: checkpoint.session_id,
      tool: Map.get(metadata, :tool),
      action: Map.get(metadata, :action),
      path_count: Map.get(metadata, :path_count),
      paths: checkpoint_paths(checkpoint)
    }
  end

  defp checkpoint_paths(checkpoint) do
    checkpoint
    |> get_in([:state, :filesystem, :files])
    |> case do
      files when is_list(files) -> Enum.map(files, & &1.path)
      _ -> []
    end
  end

  defp checkpoint_event_context(checkpoint, opts) do
    %{
      run_id: normalize_event_id(opts[:run_id]),
      session_key:
        normalize_event_id(opts[:session_key]) ||
          normalize_event_id(opts[:session_id]) ||
          normalize_event_id(checkpoint.session_id),
      agent_id: normalize_event_id(opts[:agent_id]),
      parent_run_id: normalize_event_id(opts[:parent_run_id]),
      checkpoint_id: checkpoint.id
    }
  end

  defp normalize_event_id(value) when is_binary(value) and value != "", do: value
  defp normalize_event_id(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_event_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_event_id(_), do: nil

  defp snapshot_budget(opts) do
    limits = %{
      bytes: Keyword.get(opts, :max_total_bytes, 50 * 1024 * 1024),
      entries: Keyword.get(opts, :max_entries, 10_000),
      max_bytes: Keyword.get(opts, :max_bytes, 10 * 1024 * 1024),
      max_depth: Keyword.get(opts, :max_depth, 128)
    }

    if Enum.all?(limits, fn {_key, value} -> is_integer(value) and value >= 0 end),
      do: {:ok, limits},
      else: {:error, :invalid_snapshot_limits}
  end

  defp consume_budget(budget, size, depth) do
    cond do
      depth > budget.max_depth -> {:error, :snapshot_depth_exceeded}
      budget.entries < 1 -> {:error, :snapshot_entries_exceeded}
      size > budget.bytes -> {:error, :snapshot_bytes_exceeded}
      true -> {:ok, %{budget | entries: budget.entries - 1, bytes: budget.bytes - size}}
    end
  end

  defp snapshot_files(paths, cwd, opts) do
    with {:ok, budget} <- snapshot_budget(opts) do
      paths
      |> Enum.map(&Path.expand(&1, cwd))
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, [], budget}, fn path, {:ok, acc, remaining} ->
        with :ok <- safe_parents(path),
             {:ok, node, remaining} <- snapshot_node(path, remaining, 0, false) do
          {:cont, {:ok, [Map.put(node, :path, path) | acc], remaining}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, snapshots, _} -> {:ok, Enum.reverse(snapshots)}
        error -> error
      end
    end
  end

  defp snapshot_node(path, budget, depth, fingerprint?) do
    with {:ok, budget} <- consume_budget(budget, 0, depth) do
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size, mode: mode} = stat} ->
          with :ok <- check_file_size(path, size, budget.max_bytes),
               {:ok, budget} <- reserve_bytes(budget, size),
               {:ok, content} <- read_snapshot_content(path, fingerprint?, size),
               {:ok, current} <- File.lstat(path),
               true <-
                 current.type == :regular and current.inode == stat.inode and
                   current.size == size and current.mode == mode do
            node = %{exists: true, type: "regular", size: size, mode: mode}
            key = if fingerprint?, do: :content_hash, else: :content_b64
            value = if fingerprint?, do: content, else: Base.encode64(content)
            {:ok, Map.put(node, key, value), budget}
          else
            false -> {:error, {:file_changed_during_capture, path}}
            {:error, _} = error -> error
          end

        {:ok, %File.Stat{type: :directory, mode: mode}} ->
          with {:ok, names} <- File.ls(path),
               true <- length(names) <= budget.entries,
               {:ok, entries, budget} <-
                 snapshot_children(path, Enum.sort(names), budget, depth, fingerprint?) do
            {:ok, %{exists: true, type: "directory", mode: mode, entries: entries}, budget}
          else
            false -> {:error, :snapshot_entries_exceeded}
            {:error, _} = error -> error
          end

        {:ok, %File.Stat{type: :symlink}} ->
          with {:ok, target} <- File.read_link(path),
               {:ok, budget} <- reserve_bytes(budget, byte_size(target)) do
            {:ok, %{exists: true, type: "symlink", target: target}, budget}
          end

        {:ok, %File.Stat{type: type}} ->
          {:error, {:unsupported_file_type, path, type}}

        {:error, :enoent} ->
          {:ok, %{exists: false, type: nil, size: nil, mode: nil, content_b64: nil}, budget}

        {:error, reason} ->
          {:error, {:stat_failed, path, reason}}
      end
    end
  end

  defp reserve_bytes(budget, size) when size <= budget.bytes,
    do: {:ok, %{budget | bytes: budget.bytes - size}}

  defp reserve_bytes(_budget, _size), do: {:error, :snapshot_bytes_exceeded}

  defp check_file_size(_path, size, max) when size <= max, do: :ok
  defp check_file_size(path, size, max), do: {:error, {:file_too_large, path, size, max}}

  defp read_snapshot_content(path, fingerprint?, size) do
    case File.open(path, [:read, :binary], fn io ->
           if fingerprint? do
             read_file_hash(io, size, :crypto.hash_init(:sha256))
           else
             case IO.binread(io, size + 1) do
               :eof when size == 0 -> {:ok, ""}
               content when is_binary(content) and byte_size(content) == size -> {:ok, content}
               {:error, _} = error -> error
               _ -> {:error, :file_changed_during_capture}
             end
           end
         end) do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  defp read_file_hash(io, 0, hash) do
    case IO.binread(io, 1) do
      :eof -> {:ok, :crypto.hash_final(hash)}
      _ -> {:error, :file_changed_during_capture}
    end
  end

  defp read_file_hash(io, remaining, hash) do
    case IO.binread(io, min(remaining, 65_536)) do
      content when is_binary(content) ->
        read_file_hash(io, remaining - byte_size(content), :crypto.hash_update(hash, content))

      {:error, _} = error ->
        error

      _ ->
        {:error, :file_changed_during_capture}
    end
  end

  defp snapshot_children(path, names, budget, depth, fingerprint?) do
    Enum.reduce_while(names, {:ok, [], budget}, fn name, {:ok, acc, remaining} ->
      case snapshot_node(Path.join(path, name), remaining, depth + 1, fingerprint?) do
        {:ok, node, remaining} ->
          {:cont, {:ok, [%{name: name, snapshot: node} | acc], remaining}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries, remaining} -> {:ok, Enum.reverse(entries), remaining}
      error -> error
    end
  end

  defp safe_parents(path) do
    parent = Path.dirname(path)

    if parent == path do
      :ok
    else
      with :ok <- safe_parents(parent) do
        case File.lstat(parent) do
          {:ok, %{type: :directory}} -> :ok
          {:error, :enoent} -> :ok
          _ -> {:error, {:unsafe_parent, parent}}
        end
      end
    end
  end

  defp filesystem_checkpoint?(checkpoint) do
    metadata = Map.get(checkpoint, :metadata, %{})
    Map.get(metadata, :kind) == "filesystem"
  end

  defp filesystem_files(checkpoint) do
    if filesystem_checkpoint?(checkpoint) do
      files = get_in(checkpoint, [:state, :filesystem, :files]) || []
      {:ok, files}
    else
      {:error, :not_filesystem_checkpoint}
    end
  end

  defp selected_snapshot_paths(files, nil), do: {:ok, Enum.map(files, & &1.path)}

  defp selected_snapshot_paths(files, paths) when is_list(paths) do
    available = MapSet.new(Enum.map(files, & &1.path))
    selected = paths |> Enum.map(&Path.expand/1) |> Enum.uniq()
    missing = Enum.reject(selected, &MapSet.member?(available, &1))

    case missing do
      [] -> {:ok, selected}
      [path | _] -> {:error, {:path_not_in_checkpoint, path}}
    end
  end

  defp selected_snapshot_paths(_files, _paths), do: {:error, :invalid_paths}

  defp resource_diff(snapshot) do
    before_hash =
      snapshot
      |> Map.delete(:path)
      |> hash_snapshot()
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))

    case filesystem_fingerprint(snapshot.path) do
      {:ok, ^before_hash} ->
        nil

      result ->
        %{
          path: snapshot.path,
          before_exists: snapshot.exists,
          after_exists: match?({:ok, _}, File.lstat(snapshot.path)),
          diff:
            "#{snapshot.path}: filesystem tree, mode or identity changed#{if match?({:error, _}, result), do: " (current tree unavailable)", else: ""}"
        }
    end
  end

  defp hash_snapshot(%{type: "regular", content_b64: content} = node) do
    node
    |> Map.delete(:content_b64)
    |> Map.put(:content_hash, :crypto.hash(:sha256, Base.decode64!(content)))
  end

  defp hash_snapshot(%{type: "directory", entries: entries} = node),
    do: %{node | entries: Enum.map(entries, &%{&1 | snapshot: hash_snapshot(&1.snapshot)})}

  defp hash_snapshot(node), do: node

  defp diff_snapshot(snapshot) do
    case {snapshot.type, File.lstat(snapshot.path)} do
      {type, _} when type in ["directory", "symlink"] ->
        resource_diff(snapshot)

      {_, {:ok, %{type: type}}} when type != :regular ->
        resource_diff(snapshot)

      _ ->
        before_content = snapshot_content(snapshot)
        after_content = current_content(snapshot.path)

        if before_content == after_content do
          resource_diff(snapshot)
        else
          %{
            path: snapshot.path,
            before_exists: snapshot.exists,
            after_exists: not is_nil(after_content),
            diff: unified_diff(snapshot.path, before_content, after_content)
          }
        end
    end
  end

  defp snapshot_content(%{exists: false}), do: nil

  defp snapshot_content(%{content_b64: content_b64}) when is_binary(content_b64) do
    Base.decode64!(content_b64)
  end

  defp current_content(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp unified_diff(path, before_content, after_content) do
    before_lines = split_lines(before_content)
    after_lines = split_lines(after_content)

    body =
      cond do
        is_nil(before_content) ->
          Enum.map(after_lines, &"+#{&1}")

        is_nil(after_content) ->
          Enum.map(before_lines, &"-#{&1}")

        true ->
          removed = Enum.map(before_lines, &"-#{&1}")
          added = Enum.map(after_lines, &"+#{&1}")
          removed ++ added
      end

    Enum.join(["--- #{path} (checkpoint)", "+++ #{path} (current)", "@@"] ++ body, "\n")
  end

  defp split_lines(nil), do: []

  defp split_lines(content) do
    content
    |> String.split("\n", trim: false)
    |> drop_final_empty_line()
  end

  defp drop_final_empty_line(lines) do
    case Enum.reverse(lines) do
      ["" | rest] -> Enum.reverse(rest)
      _ -> lines
    end
  end

  defp format_filesystem_diffs([]), do: "No filesystem changes since checkpoint."

  defp format_filesystem_diffs(diffs) do
    diffs
    |> Enum.map(& &1.diff)
    |> Enum.join("\n\n")
  end

  defp restore_limits(checkpoint, opts) do
    limits = get_in(checkpoint, [:state, :filesystem, :capture_limits]) || %{}
    allowed = [:max_bytes, :max_total_bytes, :max_entries, :max_depth]

    if is_map(limits) and Enum.all?(Map.keys(limits), &(&1 in allowed)),
      do: {:ok, Keyword.merge(Map.to_list(limits), opts)},
      else: {:error, :invalid_snapshot_limits}
  end

  defp validate_restore(files, opts) do
    with {:ok, budget} <- snapshot_budget(opts) do
      Enum.reduce_while(files, {:ok, budget}, fn snapshot, {:ok, remaining} ->
        with %{path: path} when is_binary(path) <- snapshot,
             true <- Path.expand(path) == path and Path.dirname(path) != path,
             :ok <- safe_parents(path),
             {:ok, remaining} <- validate_node(snapshot, remaining, 0) do
          {:cont, {:ok, remaining}}
        else
          _ -> {:halt, {:error, :invalid_or_unsafe_snapshot}}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp validate_node(node, budget, depth) do
    with {:ok, budget} <- consume_budget(budget, 0, depth) do
      validate_node_content(node, budget, depth)
    end
  end

  defp validate_node_content(%{exists: false}, budget, _depth), do: {:ok, budget}

  defp validate_node_content(
         %{exists: true, type: "regular", content_b64: encoded, size: size, mode: mode},
         budget,
         _depth
       )
       when is_binary(encoded) and is_integer(size) and size >= 0 and is_integer(mode) do
    with true <- size <= budget.max_bytes and byte_size(encoded) <= 4 * div(size + 2, 3),
         {:ok, content} <- Base.decode64(encoded),
         true <- byte_size(content) == size do
      reserve_bytes(budget, size)
    else
      _ -> {:error, :invalid_snapshot_content}
    end
  end

  defp validate_node_content(
         %{exists: true, type: "symlink", target: target},
         budget,
         _depth
       )
       when is_binary(target) and target != "" do
    if String.contains?(target, <<0>>),
      do: {:error, :invalid_symlink_target},
      else: reserve_bytes(budget, byte_size(target))
  end

  defp validate_node_content(
         %{exists: true, type: "directory", entries: entries, mode: mode},
         budget,
         depth
       )
       when is_list(entries) and is_integer(mode) do
    names = Enum.map(entries, fn entry -> if is_map(entry), do: Map.get(entry, :name) end)

    if length(entries) <= budget.entries and length(Enum.uniq(names)) == length(names) and
         Enum.all?(names, &valid_entry_name?/1) do
      Enum.reduce_while(entries, {:ok, budget}, fn entry, {:ok, remaining} ->
        case validate_node(Map.get(entry, :snapshot), remaining, depth + 1) do
          {:ok, remaining} -> {:cont, {:ok, remaining}}
          error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_directory_entries}
    end
  end

  defp validate_node_content(_node, _budget, _depth), do: {:error, :invalid_snapshot}

  defp valid_entry_name?(name) when is_binary(name),
    do: name not in ["", ".", ".."] and not String.contains?(name, ["/", <<0>>])

  defp valid_entry_name?(_), do: false

  defp restore_snapshot(%{path: path} = snapshot) do
    with :ok <- safe_parents(path),
         :ok <- remove_tree(path),
         :ok <- restore_node(path, snapshot) do
      :ok
    else
      {:error, reason} -> {:error, {:restore_write_failed, path, reason}}
    end
  end

  defp remove_tree(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory, mode: mode}} ->
        # Owner access is temporary; the recorded modes are reapplied after rebuild.
        with :ok <- File.chmod(path, Bitwise.bor(mode, 0o700)),
             {:ok, names} <- File.ls(path),
             :ok <-
               Enum.reduce_while(names, :ok, fn name, :ok ->
                 case remove_tree(Path.join(path, name)) do
                   :ok -> {:cont, :ok}
                   error -> {:halt, error}
                 end
               end),
             :ok <- File.rmdir(path),
             do: :ok

      {:ok, _} ->
        File.rm(path)

      {:error, _} = error ->
        error
    end
  end

  defp restore_node(_path, %{exists: false}), do: :ok

  defp restore_node(path, %{type: "regular", content_b64: encoded, mode: mode}) do
    with {:ok, content} <- Base.decode64(encoded),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content),
         :ok <- maybe_chmod(path, mode),
         do: :ok
  end

  defp restore_node(path, %{type: "symlink", target: target}) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: File.ln_s(target, path)
  end

  defp restore_node(path, %{type: "directory", entries: entries, mode: mode}) do
    with :ok <- File.mkdir_p(path),
         :ok <-
           Enum.reduce_while(entries, :ok, fn entry, :ok ->
             case restore_node(Path.join(path, entry.name), entry.snapshot) do
               :ok -> {:cont, :ok}
               error -> {:halt, error}
             end
           end),
         :ok <- maybe_chmod(path, mode),
         do: :ok
  end

  defp maybe_chmod(_path, nil), do: :ok
  defp maybe_chmod(path, mode), do: File.chmod(path, mode)
end
