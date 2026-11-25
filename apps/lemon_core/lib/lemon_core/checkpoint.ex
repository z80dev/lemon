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
  Restore rechecks all selected parent paths before deleting any root, then
  performs every removal, write, symlink creation and chmod through
  `LemonCore.ConfinedFS` directory descriptors walked from `/` without following
  symlinks: a concurrent writer that swaps a checked parent directory (or a
  directory inside a root being replaced) for a symlink makes the restore fail
  with `{:restore_write_failed, path, :symlink}` or keeps it on the original
  directory; it cannot redirect it outside the tree.

  Checkpoint ids must match `chk_` followed by 16 lowercase hex digits; any
  other id is reported as `:not_found` before the filesystem is touched.

  User-facing access is owner-scoped: `diff_filesystem/3`,
  `restore_filesystem/3` and `delete/3` take the owning session id as a
  required argument, and a checkpoint owned by another session (or a missing or
  malformed owner) is reported as `:not_found` and left untouched.
  `trusted_restore_filesystem/2` skips the owner check and is reserved for
  rewind, which has already proven provenance from its own session journal.

  Interactive restores preview first. `restore_preview/3` issues a random,
  single-use `confirm_token` and keeps only its SHA-256 server-side
  (`:checkpoint_restore_confirmations` Store table) together with
  the authorized `:caller`, the checkpoint id, owner and revision (a digest of
  the stored checkpoint record), the selected roots and their filesystem
  fingerprints, expiring after five minutes. `confirmed_restore_filesystem/4`
  atomically and durably consumes the record (`Store.take/4` with
  `durable: true`) before checking anything else, so a token is spent by its
  first use, successful or not, and the spend survives a crash before any file
  changes. An uncertain consumption is `{:error, :confirmation_unavailable}`
  and restores nothing. A token that was never issued, is spent or expired, or
  was issued to another caller is `{:error, :invalid_confirmation}`; a changed
  checkpoint, root selection or tree is `{:error, :stale_confirmation}`. None
  of these touches the filesystem, and recreating an earlier tree never
  revives a spent token.

  Filesystem checkpoints record their captured roots; diff and restore reject
  snapshots whose paths are not exactly those recorded roots, and checkpoints
  captured before roots were recorded are refused. Diff refuses to read through
  a symlinked ancestor or leaf.

  Capture, fingerprint and diff read through `LemonCore.ConfinedFS` handles
  walked from `/`: every component is opened without following symlinks and
  file content is read only from the stat'ed inode, so a parent swapped after
  the checks cannot make them read content from outside the tree. Recorded
  modes keep the `File.lstat/1` representation (file type bits included).

  Remaining race:

    * The confirmation fingerprint is compared before `restore_loaded/2`
      validates and mutates the roots, and nothing locks the tree in between.
      A concurrent agent or workspace writer that changes a root after that
      comparison has its change overwritten by the restore, even though the
      confirmed preview never showed it. There is no defined concurrent-writer
      boundary yet.
  """

  require Logger

  alias LemonCore.ConfinedFS

  @checkpoint_version "1.0"
  @checkpoint_id_pattern ~r/\Achk_[0-9a-f]{16}\z/
  @confirmation_table :checkpoint_restore_confirmations
  @confirmation_ttl_ms 5 * 60 * 1000
  @confirmation_bytes 24

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
            roots: Enum.map(snapshots, & &1.path),
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
         {:ok, node, _budget} <- snapshot_root(Path.expand(path), budget, true) do
      {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(node))}
    end
  rescue
    _ -> {:error, :fingerprint_failed}
  end

  @doc "Owner-scoped diff; another session's checkpoint is `:not_found`."
  @spec diff_filesystem(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def diff_filesystem(checkpoint_id, owner, opts \\ []) when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- load_owned(checkpoint_id, owner),
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

  @doc "Owner-scoped restore; another session's checkpoint is `:not_found`."
  @spec restore_filesystem(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore_filesystem(checkpoint_id, owner, opts \\ []) when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- load_owned(checkpoint_id, owner) do
      restore_loaded(checkpoint, opts)
    end
  end

  @doc """
  Owner-scoped restore preview for interactive confirmation.

  Returns the paths that differ from the checkpoint and a freshly issued,
  random `confirm_token`. Only the token's digest is stored, bound to
  `opts[:caller]` (required; any term identifying the authorized caller), the
  checkpoint id, owner and revision, the selected roots and their current
  filesystem fingerprints. It expires after five minutes and is consumed by
  the first `confirmed_restore_filesystem/4` call that presents it.
  """
  @spec restore_preview(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore_preview(checkpoint_id, owner, opts \\ []) when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- load_owned(checkpoint_id, owner),
         {:ok, caller} <- confirmation_caller(opts),
         {:ok, files} <- filesystem_files(checkpoint),
         {:ok, paths} <- selected_snapshot_paths(files, opts[:paths]),
         {:ok, binding} <- confirmation_binding(checkpoint, caller, paths, opts),
         {:ok, token} <- issue_confirmation(binding) do
      changed =
        files
        |> Enum.filter(&(&1.path in paths))
        |> Enum.map(&diff_snapshot/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.path)

      {:ok,
       %{
         checkpoint_id: checkpoint.id,
         changed: changed,
         confirm_token: token,
         expires_in_ms: @confirmation_ttl_ms
       }}
    end
  end

  @doc """
  Owner-scoped restore that consumes a token issued by `restore_preview/3`.

  The stored confirmation is taken atomically before any other check, so each
  token authorizes at most one attempt. A missing token is
  `{:error, :confirmation_required}`; a token that was never issued, is spent
  or expired, or was issued to another caller, owner or checkpoint is
  `{:error, :invalid_confirmation}`; a changed checkpoint revision, root
  selection or tree fingerprint is `{:error, :stale_confirmation}`. None of
  them touches the filesystem.
  """
  @spec confirmed_restore_filesystem(String.t(), String.t(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def confirmed_restore_filesystem(checkpoint_id, owner, confirm_token, opts \\ [])
      when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- load_owned(checkpoint_id, owner),
         :ok <- confirmation_present(confirm_token),
         {:ok, issued} <- take_confirmation(confirm_token),
         {:ok, caller} <- confirmation_caller(opts),
         :ok <- issued_to(issued, caller, checkpoint),
         {:ok, files} <- filesystem_files(checkpoint),
         {:ok, paths} <- selected_snapshot_paths(files, opts[:paths]),
         {:ok, current} <- confirmation_binding(checkpoint, caller, paths, opts),
         :ok <- unchanged_since_preview(issued, current) do
      restore_loaded(checkpoint, opts)
    end
  end

  defp confirmation_present(token) when is_binary(token) and token != "", do: :ok
  defp confirmation_present(_token), do: {:error, :confirmation_required}

  defp confirmation_caller(opts) do
    case Keyword.get(opts, :caller) do
      nil -> {:error, :confirmation_caller_required}
      caller -> {:ok, caller}
    end
  end

  defp confirmation_binding(checkpoint, caller, paths, opts) do
    with {:ok, limits} <- restore_limits(checkpoint, opts),
         {:ok, current} <- current_fingerprints(paths, limits) do
      {:ok,
       %{
         caller: caller,
         checkpoint_id: checkpoint.id,
         owner: checkpoint.session_id,
         revision: digest(checkpoint),
         roots: Enum.sort(paths),
         fingerprint: current |> Enum.sort() |> digest()
       }}
    end
  end

  defp digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

  defp confirmation_key(token), do: :crypto.hash(:sha256, token)

  defp issue_confirmation(binding) do
    now = System.system_time(:millisecond)
    prune_confirmations(now)
    token = Base.url_encode64(:crypto.strong_rand_bytes(@confirmation_bytes), padding: false)
    record = Map.put(binding, :expires_at_ms, now + @confirmation_ttl_ms)

    case LemonCore.Store.put_new(@confirmation_table, confirmation_key(token), record) do
      :ok -> {:ok, token}
      {:error, _reason} -> {:error, :confirmation_unavailable}
    end
  end

  # Expired records are removed only if unchanged since they were listed.
  defp prune_confirmations(now) do
    for {key, %{expires_at_ms: expires_at} = record} <-
          LemonCore.Store.list(@confirmation_table),
        expires_at <= now do
      _ = LemonCore.Store.compare_and_delete(@confirmation_table, key, record)
    end

    :ok
  end

  # Consumption must be durable before anything else happens: an uncertain
  # removal could leave the token valid after a crash, so it fails closed.
  defp take_confirmation(token) do
    now = System.system_time(:millisecond)

    case LemonCore.Store.take(LemonCore.Store, @confirmation_table, confirmation_key(token),
           durable: true
         ) do
      %{expires_at_ms: expires_at} = issued when expires_at > now -> {:ok, issued}
      {:error, _reason} -> {:error, :confirmation_unavailable}
      _missing_or_expired -> {:error, :invalid_confirmation}
    end
  end

  defp issued_to(issued, caller, checkpoint) do
    if issued.caller === caller and issued.checkpoint_id == checkpoint.id and
         issued.owner == checkpoint.session_id,
       do: :ok,
       else: {:error, :invalid_confirmation}
  end

  defp unchanged_since_preview(issued, current) do
    if Map.take(issued, [:revision, :roots, :fingerprint]) ==
         Map.take(current, [:revision, :roots, :fingerprint]),
       do: :ok,
       else: {:error, :stale_confirmation}
  end

  # Each root's current tree identity; an unreadable or over-budget tree has
  # no fingerprint, so no token can be issued for it.
  defp current_fingerprints(paths, limits) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case filesystem_fingerprint(path, limits) do
        {:ok, fingerprint} -> {:cont, {:ok, [{path, fingerprint} | acc]}}
        {:error, _} -> {:halt, {:error, :restore_preview_unavailable}}
      end
    end)
  end

  @doc """
  Restore without an owner check. Only for rewind, whose checkpoint ids come
  from its own session journal; never pass user- or model-selected ids.
  """
  @spec trusted_restore_filesystem(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def trusted_restore_filesystem(checkpoint_id, opts \\ []) when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- load(checkpoint_id) do
      restore_loaded(checkpoint, opts)
    end
  end

  defp restore_loaded(checkpoint, opts) do
    with {:ok, files} <- filesystem_files(checkpoint),
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

  @doc "Whether `checkpoint_id` has the generated `chk_<16 hex>` shape."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(checkpoint_id) when is_binary(checkpoint_id),
    do: Regex.match?(@checkpoint_id_pattern, checkpoint_id)

  def valid_id?(_checkpoint_id), do: false

  @spec load(String.t()) :: {:ok, checkpoint()} | {:error, term()}
  def load(checkpoint_id) when is_binary(checkpoint_id) do
    if valid_id?(checkpoint_id), do: read_checkpoint(checkpoint_id), else: {:error, :not_found}
  end

  defp read_checkpoint(checkpoint_id) do
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

  # A mismatched or malformed owner is indistinguishable from a missing checkpoint.
  defp load_owned(checkpoint_id, owner) when is_binary(owner) and owner != "" do
    case load(checkpoint_id) do
      {:ok, %{session_id: ^owner} = checkpoint} -> {:ok, checkpoint}
      {:ok, _other_owner} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp load_owned(_checkpoint_id, _owner), do: {:error, :not_found}

  @doc """
  Snapshot files of a filesystem checkpoint, confined to its recorded roots.
  Returns `{:error, :invalid_or_unsafe_snapshot}` for checkpoints without
  recorded roots (captured before they were recorded) or with other paths.
  """
  @spec confined_filesystem_files(checkpoint()) :: {:ok, list()} | {:error, term()}
  def confined_filesystem_files(checkpoint), do: filesystem_files(checkpoint)

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

  @doc "Owner-scoped delete; another session's checkpoint is `:not_found`."
  @spec delete(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(checkpoint_id, owner, opts \\ []) when is_binary(checkpoint_id) do
    with {:ok, checkpoint} <- load_owned(checkpoint_id, owner) do
      remove_checkpoint(checkpoint_id, {:ok, checkpoint}, opts)
    end
  end

  # Shared deletion boundary: ids embedded in checkpoint JSON (delete_all/prune)
  # are validated here too, so a forged `id` never reaches File.rm.
  defp remove_checkpoint(checkpoint_id, existing, opts) do
    if valid_id?(checkpoint_id),
      do: rm_checkpoint(checkpoint_id, existing, opts),
      else: {:error, :not_found}
  end

  defp rm_checkpoint(checkpoint_id, existing, opts) do
    case File.rm(checkpoint_path(checkpoint_id)) do
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
      remove_checkpoint(checkpoint.id, {:ok, checkpoint}, [])
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
    valid_id?(checkpoint_id) and File.exists?(checkpoint_path(checkpoint_id))
  end

  @spec prune(String.t(), non_neg_integer()) :: {:ok, non_neg_integer()}
  def prune(session_id, keep \\ 10)
      when is_binary(session_id) and is_integer(keep) and keep >= 0 do
    checkpoints = list(session_id)
    to_delete = Enum.drop(checkpoints, keep)

    Enum.each(to_delete, fn checkpoint ->
      remove_checkpoint(checkpoint.id, {:ok, checkpoint}, [])
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
             {:ok, node, remaining} <- snapshot_root(path, remaining, false) do
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

  # Capture and fingerprint read through `ConfinedFS` handles walked from `/`
  # without following symlinks, so a parent swapped after `safe_parents/1`
  # cannot make them read (and store) content from outside the root.
  defp snapshot_root(path, budget, fingerprint?) do
    case with_confined_entry(path, fn fs, parent, name ->
           snapshot_node(fs, parent, name, path, budget, 0, fingerprint?)
         end) do
      {:ok, result} -> result
      {:error, :enoent} -> snapshot_node(nil, nil, nil, path, budget, 0, fingerprint?)
      {:error, reason} -> {:error, {:stat_failed, path, reason}}
    end
  end

  # `{:ok, fun.(fs, parent_handle, name)}` for the absolute `path`, or the
  # session/parent-walk error (`:enoent` for a missing parent).
  defp with_confined_entry(path, fun) do
    ConfinedFS.with_root("/", fn fs ->
      {:ok, parts} = ConfinedFS.beneath("/", path)

      with {:ok, parent, name} <- ConfinedFS.open_parent(fs, :root, parts) do
        try do
          {:ok, fun.(fs, parent, name)}
        after
          ConfinedFS.close_dir(fs, parent)
        end
      end
    end)
  end

  @absent_node %{exists: false, type: nil, size: nil, mode: nil, content_b64: nil}

  defp snapshot_node(fs, dir, name, path, budget, depth, fingerprint?) do
    with {:ok, budget} <- consume_budget(budget, 0, depth) do
      case if(fs, do: ConfinedFS.stat(fs, dir, name), else: {:error, :enoent}) do
        {:ok, %ConfinedFS.Stat{type: :regular, size: size} = stat} ->
          # A checkpoint never copies (or fingerprints) a Lemon credential file.
          with :ok <- credential_check(path),
               :ok <- check_file_size(path, size, budget.max_bytes),
               {:ok, budget} <- reserve_bytes(budget, size),
               {:ok, content, current} <- read_snapshot_content(fs, dir, name, path, stat) do
            node = %{exists: true, type: "regular", size: size, mode: lstat_mode(current)}

            if fingerprint?,
              do: {:ok, Map.put(node, :content_hash, :crypto.hash(:sha256, content)), budget},
              else: {:ok, Map.put(node, :content_b64, Base.encode64(content)), budget}
          end

        {:ok, %ConfinedFS.Stat{type: :directory} = stat} ->
          snapshot_directory(fs, dir, name, path, stat, budget, depth, fingerprint?)

        {:ok, %ConfinedFS.Stat{type: :symlink}} ->
          with {:ok, target} <- ConfinedFS.readlink(fs, dir, name),
               {:ok, budget} <- reserve_bytes(budget, byte_size(target)) do
            {:ok, %{exists: true, type: "symlink", target: target}, budget}
          else
            {:error, reason} when is_atom(reason) -> {:error, {:stat_failed, path, reason}}
          end

        {:ok, %ConfinedFS.Stat{type: type}} ->
          {:error, {:unsupported_file_type, path, type}}

        {:error, :enoent} ->
          {:ok, @absent_node, budget}

        {:error, reason} ->
          {:error, {:stat_failed, path, reason}}
      end
    end
  end

  # `File.Stat`-compatible mode (file type bits included), so checkpoints and
  # fingerprints keep the representation captured with `File.lstat/1`.
  defp lstat_mode(%ConfinedFS.Stat{type: :regular, mode: mode}), do: Bitwise.bor(0o100000, mode)
  defp lstat_mode(%ConfinedFS.Stat{type: :directory, mode: mode}), do: Bitwise.bor(0o040000, mode)

  defp reserve_bytes(budget, size) when size <= budget.bytes,
    do: {:ok, %{budget | bytes: budget.bytes - size}}

  defp reserve_bytes(_budget, _size), do: {:error, :snapshot_bytes_exceeded}

  defp check_file_size(_path, size, max) when size <= max, do: :ok
  defp check_file_size(path, size, max), do: {:error, {:file_too_large, path, size, max}}

  defp credential_check(path) do
    case LemonCore.CredentialPaths.check_read(path) do
      :ok -> :ok
      {:error, _message} -> {:error, {:protected_credential, path}}
    end
  end

  # Reads exactly the stat'ed file; growth, replacement or a mode or size
  # change in between is a capture failure.
  defp read_snapshot_content(fs, dir, name, path, %ConfinedFS.Stat{size: size} = stat) do
    case ConfinedFS.read(fs, dir, name, size, expect: stat) do
      {:ok, content, %ConfinedFS.Stat{size: ^size, mode: mode} = current}
      when byte_size(content) == size and mode == stat.mode ->
        {:ok, content, current}

      {:ok, _content, _current} ->
        {:error, {:file_changed_during_capture, path}}

      {:error, reason} when reason in [:changed, :too_large, :not_regular, :symlink, :enoent] ->
        {:error, {:file_changed_during_capture, path}}

      {:error, _} = error ->
        error
    end
  end

  defp snapshot_directory(fs, dir, name, path, stat, budget, depth, fingerprint?) do
    case ConfinedFS.open_dir(fs, dir, [name]) do
      {:ok, handle} ->
        try do
          with {:ok, %ConfinedFS.Stat{} = opened} <- ConfinedFS.stat(fs, handle),
               true <- ConfinedFS.Stat.same_object?(opened, stat),
               {:ok, listed} <- ConfinedFS.list(fs, handle, max_entries: budget.entries),
               names = listed |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
               {:ok, entries, budget} <-
                 snapshot_children(fs, handle, path, names, budget, depth, fingerprint?) do
            {:ok, %{exists: true, type: "directory", mode: lstat_mode(opened), entries: entries},
             budget}
          else
            false -> {:error, {:file_changed_during_capture, path}}
            {:error, :too_many} -> {:error, :snapshot_entries_exceeded}
            {:error, reason} when is_atom(reason) -> {:error, {:stat_failed, path, reason}}
            error -> error
          end
        after
          ConfinedFS.close_dir(fs, handle)
        end

      {:error, reason} ->
        {:error, {:stat_failed, path, reason}}
    end
  end

  defp snapshot_children(fs, dir, path, names, budget, depth, fingerprint?) do
    Enum.reduce_while(names, {:ok, [], budget}, fn name, {:ok, acc, remaining} ->
      case snapshot_node(
             fs,
             dir,
             name,
             Path.join(path, name),
             remaining,
             depth + 1,
             fingerprint?
           ) do
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
      filesystem = get_in(checkpoint, [:state, :filesystem]) || %{}
      files = Map.get(filesystem, :files) || []
      roots = Map.get(filesystem, :roots)

      if confined_to_roots?(files, roots),
        do: {:ok, files},
        else: {:error, :invalid_or_unsafe_snapshot}
    else
      {:error, :not_filesystem_checkpoint}
    end
  end

  # Every snapshot must be one recorded captured root (absolute, normalized,
  # restored at most once); entry names below roots are validated separately.
  defp confined_to_roots?(files, roots) when is_list(files) and is_list(roots) do
    paths = Enum.map(files, &(is_map(&1) && Map.get(&1, :path)))

    Enum.all?(roots, &absolute_root?/1) and Enum.all?(paths, &(&1 in roots)) and
      length(Enum.uniq(paths)) == length(paths)
  end

  defp confined_to_roots?(_files, _roots), do: false

  defp absolute_root?(path) when is_binary(path),
    do: Path.type(path) == :absolute and Path.expand(path) == path and Path.dirname(path) != path

  defp absolute_root?(_path), do: false

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
          after_exists: current_exists?(snapshot.path),
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
    case safe_parents(snapshot.path) do
      :ok -> diff_confined_snapshot(snapshot)
      {:error, _} -> unavailable_diff(snapshot)
    end
  end

  # A symlinked ancestor would let the read escape the recorded root, so nothing
  # below it is read or stat'ed.
  defp unavailable_diff(snapshot) do
    %{
      path: snapshot.path,
      before_exists: snapshot.exists,
      after_exists: nil,
      diff: "#{snapshot.path}: current path is unavailable (symlinked parent directory)"
    }
  end

  defp diff_confined_snapshot(%{type: type} = snapshot) when type in ["directory", "symlink"],
    do: resource_diff(snapshot)

  defp diff_confined_snapshot(snapshot) do
    case current_content(snapshot.path) do
      :unavailable -> unavailable_diff(snapshot)
      :not_content -> resource_diff(snapshot)
      content -> content_diff(snapshot, snapshot_content(snapshot), content)
    end
  end

  defp content_diff(snapshot, before_content, after_content) do
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

  defp snapshot_content(%{exists: false}), do: nil

  defp snapshot_content(%{content_b64: content_b64}) when is_binary(content_b64) do
    Base.decode64!(content_b64)
  end

  @diff_read_max 50 * 1024 * 1024

  # Reads only a regular file reached through `ConfinedFS` handles walked from
  # `/` without following symlinks, bound to the identity of the stat'ed leaf:
  # file content (`nil` when absent), `:not_content` for another type or an
  # oversized file (compared by fingerprint instead), or `:unavailable`.
  defp current_content(path) do
    result =
      with_confined_entry(path, fn fs, parent, name ->
        case ConfinedFS.stat(fs, parent, name) do
          {:ok, %ConfinedFS.Stat{type: :regular} = leaf} ->
            case ConfinedFS.read(fs, parent, name, @diff_read_max, expect: leaf) do
              {:ok, content, _stat} -> content
              {:error, :too_large} -> :not_content
              {:error, _} -> :unavailable
            end

          {:ok, _other} ->
            :not_content

          {:error, :enoent} ->
            nil

          {:error, _} ->
            :unavailable
        end
      end)

    case result do
      {:ok, content} -> content
      {:error, :enoent} -> nil
      {:error, _} -> :unavailable
    end
  end

  defp current_exists?(path) do
    match?(
      {:ok, {:ok, _}},
      with_confined_entry(path, fn fs, parent, name -> ConfinedFS.stat(fs, parent, name) end)
    )
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

  # Every restore operation runs on directory descriptors from a session rooted
  # at `/`: the parent walk refuses symlinked components (the same rule capture
  # and validation apply) and later swaps of a walked path cannot move the open
  # handles, so removal, writes, symlink creation and chmods stay in the tree.
  defp restore_snapshot(%{path: path} = snapshot) do
    result =
      ConfinedFS.with_root("/", fn fs ->
        case open_restore_parent(fs, path, snapshot) do
          {:ok, parent, name} ->
            try do
              with :ok <- remove_entry(fs, parent, name),
                   do: restore_node(fs, parent, name, snapshot)
            after
              ConfinedFS.close_dir(fs, parent)
            end

          :absent ->
            :ok

          {:error, _} = error ->
            error
        end
      end)

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:restore_write_failed, path, reason}}
    end
  end

  # Parents are created only when something is restored below them; a missing
  # parent of an absent root means there is nothing to remove.
  defp open_restore_parent(fs, path, %{exists: exists}) do
    {:ok, parts} = ConfinedFS.beneath("/", path)

    case ConfinedFS.open_parent(fs, :root, parts, create: exists == true) do
      {:error, :enoent} when exists != true -> :absent
      other -> other
    end
  end

  defp remove_entry(fs, parent, name) do
    case ConfinedFS.remove_tree(fs, parent, name) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  defp restore_node(_fs, _parent, _name, %{exists: false}), do: :ok

  defp restore_node(fs, parent, name, %{type: "regular", content_b64: encoded, mode: mode}) do
    with {:ok, content} <- Base.decode64(encoded),
         {:ok, _stat} <- ConfinedFS.create(fs, parent, name, content, mode: 0o600),
         do: maybe_chmod(fs, parent, name, mode)
  end

  defp restore_node(fs, parent, name, %{type: "symlink", target: target}),
    do: ConfinedFS.symlink(fs, parent, name, target)

  defp restore_node(fs, parent, name, %{type: "directory", entries: entries, mode: mode}) do
    # Owner access is temporary; the recorded mode is reapplied after rebuild.
    with :ok <- ConfinedFS.mkdir(fs, parent, name, 0o700),
         {:ok, dir} <- ConfinedFS.open_dir(fs, parent, [name]) do
      result =
        try do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case restore_node(fs, dir, entry.name, entry.snapshot) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        after
          ConfinedFS.close_dir(fs, dir)
        end

      with :ok <- result, do: maybe_chmod(fs, parent, name, mode)
    end
  end

  defp maybe_chmod(_fs, _parent, _name, nil), do: :ok
  defp maybe_chmod(fs, parent, name, mode), do: ConfinedFS.chmod(fs, parent, name, mode)
end
