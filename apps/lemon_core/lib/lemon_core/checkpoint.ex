defmodule LemonCore.Checkpoint do
  @moduledoc """
  Shared checkpoint store and filesystem rollback operations.
  """

  require Logger

  @checkpoint_dir Path.join([System.tmp_dir!(), "lemon_checkpoints"])
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
          path: String.t(),
          exists: boolean(),
          type: String.t() | nil,
          size: non_neg_integer() | nil,
          mode: non_neg_integer() | nil,
          content_b64: String.t() | nil
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
            files: snapshots
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
         {:ok, paths} <- selected_snapshot_paths(files, opts[:paths]) do
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
        case Jason.decode(content, keys: :atoms!) do
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

    @checkpoint_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(fn filename ->
      path = Path.join(@checkpoint_dir, filename)

      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content, keys: :atoms!) do
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
    Path.join(@checkpoint_dir, "#{checkpoint_id}.json")
  end

  defp ensure_checkpoint_dir do
    File.mkdir_p!(@checkpoint_dir)
  end

  defp save_checkpoint(checkpoint) do
    ensure_checkpoint_dir()
    path = checkpoint_path(checkpoint.id)

    content = Jason.encode!(checkpoint, pretty: true)
    File.write(path, content)
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

    if Process.whereis(LemonCore.PubSub) do
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

  defp snapshot_files(paths, cwd, opts) do
    paths
    |> Enum.map(&Path.expand(&1, cwd))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case snapshot_file(path, opts) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      error -> error
    end
  end

  defp snapshot_file(path, opts) do
    max_bytes = opts[:max_bytes] || 10 * 1024 * 1024

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mode: mode}} when size <= max_bytes ->
        case File.read(path) do
          {:ok, content} ->
            {:ok,
             %{
               path: path,
               exists: true,
               type: "regular",
               size: size,
               mode: mode,
               content_b64: Base.encode64(content)
             }}

          {:error, reason} ->
            {:error, {:read_failed, path, reason}}
        end

      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:error, {:file_too_large, path, size, max_bytes}}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unsupported_file_type, path, type}}

      {:error, :enoent} ->
        {:ok,
         %{
           path: path,
           exists: false,
           type: nil,
           size: nil,
           mode: nil,
           content_b64: nil
         }}

      {:error, reason} ->
        {:error, {:stat_failed, path, reason}}
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

  defp diff_snapshot(snapshot) do
    before_content = snapshot_content(snapshot)
    after_content = current_content(snapshot.path)

    if before_content == after_content do
      nil
    else
      %{
        path: snapshot.path,
        before_exists: snapshot.exists,
        after_exists: not is_nil(after_content),
        diff: unified_diff(snapshot.path, before_content, after_content)
      }
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

  defp restore_snapshot(%{exists: false, path: path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:restore_delete_failed, path, reason}}
    end
  end

  defp restore_snapshot(%{path: path, content_b64: content_b64, mode: mode}) do
    with {:ok, content} <- Base.decode64(content_b64),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content),
         :ok <- maybe_chmod(path, mode) do
      :ok
    else
      {:error, reason} -> {:error, {:restore_write_failed, path, reason}}
    end
  end

  defp maybe_chmod(_path, nil), do: :ok
  defp maybe_chmod(path, mode), do: File.chmod(path, mode)
end
