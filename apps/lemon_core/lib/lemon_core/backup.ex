defmodule LemonCore.Backup do
  @moduledoc """
  Atomic, checksum-verified backups for Lemon's per-user data directory.

  A backup is a private directory bundle containing `manifest.json`, a
  checksum for that manifest, and byte-exact files below `data/`. The final
  bundle appears with one directory rename, so an interrupted create never
  leaves a path that can be mistaken for a complete backup.

  Restore verifies the complete bundle before touching the destination. It is
  additive by default and refuses conflicting files. An overwrite is accepted
  only when the caller supplies both `overwrite: true` and a confirmation
  derived from the verified manifest digest plus the expanded target root;
  displaced files are kept in a mode-0700 sibling rollback directory.
  Structural conflicts (symlinks, special files, or a file where a parent
  directory is needed) always fail closed.

  The default contract includes durable configuration, stores, sessions,
  skills, and workspace files. It excludes installed versions and launchers,
  runtime pid/socket state, caches, logs, previous backups, restore rollback
  directories, support bundles, and symlinks. Local credential material
  (`cookie`, `env`, `secrets_master_key`, and execution-node credentials) is
  excluded unless `include_credentials: true` is explicit. Platform keychain
  contents and project-local `.lemon` directories are outside this contract.

  Backup files are opaque: Lemon never parses or prints their contents. CLI
  and list/status results expose only aggregate metadata.
  """

  import Bitwise

  alias LemonCore.Paths

  @schema 1
  @contract_version 1
  @manifest "manifest.json"
  @manifest_checksum "manifest.sha256"
  @data_dir "data"
  @max_manifest_bytes 16 * 1024 * 1024
  @max_files 100_000
  @max_path_bytes 1_024
  @copy_chunk_bytes 1024 * 1024
  @allowed_restore_modes MapSet.new([0o400, 0o500, 0o600, 0o700])

  @always_excluded_roots MapSet.new([
                           "backups",
                           "bin",
                           "cache",
                           "logs",
                           "restore-rollbacks",
                           "run",
                           "tmp",
                           "versions"
                         ])
  @credential_files MapSet.new(["cookie", "env", "secrets_master_key"])

  @type result :: {:ok, map()} | {:error, term()}

  @doc "The current on-disk backup contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc "Default directory in which backup bundles are created and listed."
  @spec default_backup_root(keyword()) :: String.t()
  def default_backup_root(opts \\ []) do
    opts
    |> paths_opts()
    |> then(&Paths.home_path("backups", &1))
  end

  @doc "Returns the documented exclusion policy without inspecting user data."
  @spec contract(keyword()) :: map()
  def contract(opts \\ []) do
    include_credentials? = Keyword.get(opts, :include_credentials, false) == true

    %{
      contract_version: @contract_version,
      scope: "user_state",
      source: "~/.lemon",
      includes: [
        "config.toml",
        "agent/",
        "store/",
        "other durable regular files not excluded below"
      ],
      excludes: exclusion_descriptions(include_credentials?),
      include_credentials: include_credentials?,
      follows_symlinks: false,
      includes_project_state: false,
      includes_platform_keychain: false
    }
  end

  @doc "Creates one atomic backup directory bundle."
  @spec create(keyword()) :: result()
  def create(opts \\ []) do
    source = source_root(opts)
    backup_root = Keyword.get(opts, :backup_root, default_backup_root(opts)) |> Path.expand()

    output =
      case Keyword.get(opts, :output) do
        path when is_binary(path) and path != "" -> Path.expand(path)
        _ -> Path.join(backup_root, default_bundle_name())
      end

    with :ok <- validate_source(source),
         :ok <- validate_output(source, output),
         {:ok, result} <- with_lock(source, fn -> do_create(source, output, opts) end) do
      {:ok, result}
    end
  end

  @doc "Lists backup manifests without reading any backed-up file contents."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    root = Keyword.get(opts, :backup_root, default_backup_root(opts)) |> Path.expand()

    case File.ls(root) do
      {:ok, entries} ->
        backups =
          entries
          |> Enum.sort(:desc)
          |> Enum.reduce([], fn entry, acc ->
            path = Path.join(root, entry)

            case read_manifest(path) do
              {:ok, manifest} -> [manifest_summary(path, manifest) | acc]
              {:error, _reason} -> acc
            end
          end)
          |> Enum.sort_by(& &1.created_at, :desc)

        {:ok, backups}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:list_failed, reason}}
    end
  end

  @doc "Verifies the manifest checksum, file set, sizes, and SHA-256 digests."
  @spec verify(Path.t(), keyword()) :: result()
  def verify(bundle, opts \\ []) do
    bundle = Path.expand(bundle)

    with :ok <- verify_bundle_root(bundle),
         :ok <- verify_private_bundle_permissions(bundle),
         {:ok, manifest, manifest_digest} <- read_verified_manifest(bundle),
         {:ok, entries} <- validate_manifest(manifest),
         :ok <- verify_exact_file_set(bundle, entries),
         :ok <- verify_entries(bundle, entries) do
      target = Keyword.get(opts, :target, source_root(opts)) |> Path.expand()

      {:ok,
       manifest_summary(bundle, manifest)
       |> Map.put(:verified, true)
       |> Map.put(:manifest_sha256, manifest_digest)
       |> Map.put(:overwrite_confirmation, overwrite_confirmation(manifest_digest, target))}
    end
  end

  @doc "Restores a fully verified bundle with fail-closed conflict handling."
  @spec restore(Path.t(), keyword()) :: result()
  def restore(bundle, opts \\ []) do
    bundle = Path.expand(bundle)
    target = target_root(opts)

    with :ok <- validate_restore_target(target),
         {:ok, summary} <- verify(bundle, Keyword.put(opts, :target, target)),
         {:ok, manifest, manifest_digest} <- read_verified_manifest(bundle),
         {:ok, entries} <- validate_manifest(manifest),
         {:ok, result} <-
           with_lock(target, fn ->
             do_restore(bundle, target, manifest, manifest_digest, entries, summary, opts)
           end) do
      {:ok, result}
    end
  end

  defp do_create(source, output, opts) do
    partial = output <> ".partial.#{unique_suffix()}"
    include_credentials? = Keyword.get(opts, :include_credentials, false) == true

    try do
      with :ok <- ensure_parent(output),
           :ok <- ensure_absent(output),
           :ok <- mkdir_p_private(Path.join(partial, @data_dir)),
           {:ok, source_files, excluded} <- collect_source_files(source, include_credentials?),
           {:ok, manifest_entries} <- copy_source_files(source, partial, source_files),
           manifest <- build_manifest(manifest_entries, excluded, include_credentials?),
           :ok <- write_manifest(partial, manifest),
           {:ok, _summary} <- verify(partial),
           :ok <- File.rename(partial, output),
           :ok <- sync_dir(Path.dirname(output)) do
        {:ok, manifest_summary(output, manifest) |> Map.put(:verified, true)}
      end
    after
      remove_partial(partial)
    end
  end

  defp do_restore(bundle, target, manifest, manifest_digest, entries, summary, opts) do
    overwrite? = Keyword.get(opts, :overwrite, false) == true
    confirmation = Keyword.get(opts, :confirmation)

    with :ok <-
           validate_restore_confirmation(
             target,
             manifest_digest,
             overwrite?,
             confirmation,
             summary.overwrite_confirmation
           ),
         {:ok, conflicts, identical} <- classify_destination(target, entries),
         :ok <- authorize_conflicts(conflicts, overwrite?),
         {:ok, stage} <- stage_restore(bundle, target, entries, identical),
         {:ok, result} <-
           apply_restore(stage, target, manifest, manifest_digest, conflicts, identical) do
      {:ok, result}
    end
  end

  defp collect_source_files(root, include_credentials?) do
    walk_source(root, "", include_credentials?, [], %{})
  end

  defp walk_source(root, relative, include_credentials?, files, excluded) do
    dir = if relative == "", do: root, else: Path.join(root, relative)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, files, excluded}, fn name, {:ok, acc, excluded_acc} ->
          rel = if relative == "", do: name, else: Path.join(relative, name)

          case exclusion_reason(rel, include_credentials?) do
            nil ->
              path = Path.join(root, rel)

              case File.lstat(path, time: :posix) do
                {:ok, %File.Stat{type: :directory}} ->
                  case walk_source(root, rel, include_credentials?, acc, excluded_acc) do
                    {:ok, nested, nested_excluded} ->
                      {:cont, {:ok, nested, nested_excluded}}

                    {:error, reason} ->
                      {:halt, {:error, reason}}
                  end

                {:ok, %File.Stat{type: :regular} = stat} ->
                  if length(acc) >= @max_files do
                    {:halt, {:error, :too_many_files}}
                  else
                    {:cont, {:ok, [{rel, stat} | acc], excluded_acc}}
                  end

                {:ok, %File.Stat{type: :symlink}} ->
                  {:cont, {:ok, acc, increment_excluded(excluded_acc, "symlink")}}

                {:ok, %File.Stat{}} ->
                  {:cont, {:ok, acc, increment_excluded(excluded_acc, "special_file")}}

                {:error, reason} ->
                  {:halt, {:error, {:stat_failed, safe_path(rel), reason}}}
              end

            reason ->
              {:cont, {:ok, acc, increment_excluded(excluded_acc, reason)}}
          end
        end)
        |> case do
          {:ok, found, skipped} -> {:ok, Enum.reverse(found), skipped}
          error -> error
        end

      {:error, reason} ->
        {:error, {:list_source_failed, safe_path(relative), reason}}
    end
  end

  defp copy_source_files(source, partial, files) do
    Enum.reduce_while(files, {:ok, []}, fn {relative, stat}, {:ok, entries} ->
      source_path = Path.join(source, relative)
      destination = Path.join([partial, @data_dir, relative])

      with {:ok, mode} <- source_restore_mode(stat.mode),
           {:ok, digest} <- copy_and_digest(source_path, destination, stat) do
        entry = %{
          "path" => relative,
          "bytes" => stat.size,
          "sha256" => digest,
          "mode" => mode
        }

        {:cont, {:ok, [entry | entries]}}
      else
        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp copy_and_digest(source, destination, before_stat) do
    with :ok <- mkdir_p_private(Path.dirname(destination)),
         {:ok, digest} <- stream_copy_and_digest(source, destination),
         {:ok, after_stat} <- File.stat(source, time: :posix),
         :ok <- unchanged?(before_stat, after_stat),
         :ok <- chmod_and_sync(destination, 0o600) do
      {:ok, digest}
    else
      {:error, {:source_changed, _} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:copy_failed, reason}}
    end
  end

  defp stream_copy_and_digest(source, destination) do
    with {:ok, input} <- File.open(source, [:read, :binary]),
         {:ok, output} <- File.open(destination, [:write, :binary]) do
      try do
        copy_chunks(input, output, :crypto.hash_init(:sha256))
      after
        File.close(input)
        File.close(output)
      end
    end
  end

  defp copy_chunks(input, output, hash) do
    case IO.binread(input, @copy_chunk_bytes) do
      :eof ->
        :ok = :file.sync(output)
        {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, {:read_failed, reason}}

      bytes when is_binary(bytes) ->
        case IO.binwrite(output, bytes) do
          :ok -> copy_chunks(input, output, :crypto.hash_update(hash, bytes))
          {:error, reason} -> {:error, {:write_failed, reason}}
        end
    end
  end

  defp unchanged?(before_stat, after_stat) do
    if before_stat.size == after_stat.size and before_stat.mtime == after_stat.mtime and
         before_stat.inode == after_stat.inode do
      :ok
    else
      {:error, {:source_changed, :retry}}
    end
  end

  defp build_manifest(entries, excluded, include_credentials?) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{
      "schema" => @schema,
      "product" => "lemon",
      "contract_version" => @contract_version,
      "id" => "backup-#{unique_suffix()}",
      "created_at" => now,
      "source" => "~/.lemon",
      "include_credentials" => include_credentials?,
      "file_count" => length(entries),
      "total_bytes" => Enum.reduce(entries, 0, &(&1["bytes"] + &2)),
      "files" => entries,
      "exclusions" => %{
        "policy" => exclusion_descriptions(include_credentials?),
        "observed_counts" => Map.new(excluded)
      },
      "redaction" => %{
        "file_contents_returned" => false,
        "absolute_source_path_returned" => false,
        "secret_values_returned" => false
      }
    }
  end

  defp write_manifest(bundle, manifest) do
    bytes = Jason.encode!(manifest, pretty: true) <> "\n"
    checksum = sha256(bytes)

    with :ok <- write_atomic_synced(Path.join(bundle, @manifest), bytes, 0o600),
         :ok <-
           write_atomic_synced(
             Path.join(bundle, @manifest_checksum),
             checksum <> "  #{@manifest}\n",
             0o600
           ) do
      :ok
    end
  end

  defp write_synced(path, bytes) do
    with {:ok, io} <- File.open(path, [:write, :binary]) do
      try do
        with :ok <- IO.binwrite(io, bytes), do: :file.sync(io)
      after
        File.close(io)
      end
    end
  end

  defp read_verified_manifest(bundle) do
    checksum_path = Path.join(bundle, @manifest_checksum)
    manifest_path = Path.join(bundle, @manifest)

    with {:ok, expected_line} <- File.read(checksum_path),
         {:ok, expected} <- parse_manifest_checksum(expected_line),
         {:ok, bytes} <- bounded_read(manifest_path, @max_manifest_bytes),
         true <- secure_equal?(expected, sha256(bytes)) || {:error, :manifest_checksum_mismatch},
         {:ok, manifest} <- Jason.decode(bytes) do
      {:ok, manifest, expected}
    else
      false -> {:error, :manifest_checksum_mismatch}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_manifest_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_manifest(bundle) do
    with :ok <- verify_bundle_root(bundle),
         {:ok, manifest, _digest} <- read_verified_manifest(bundle),
         {:ok, _entries} <- validate_manifest(manifest) do
      {:ok, manifest}
    end
  end

  defp parse_manifest_checksum(line) do
    case String.split(String.trim(line), ~r/\s+/, parts: 2) do
      [digest, @manifest] when byte_size(digest) == 64 ->
        if String.match?(digest, ~r/\A[0-9a-f]{64}\z/),
          do: {:ok, digest},
          else: {:error, :invalid_manifest_checksum}

      _ ->
        {:error, :invalid_manifest_checksum}
    end
  end

  defp validate_manifest(%{
         "schema" => @schema,
         "product" => "lemon",
         "contract_version" => @contract_version,
         "id" => id,
         "created_at" => created_at,
         "include_credentials" => include_credentials?,
         "file_count" => file_count,
         "total_bytes" => total_bytes,
         "files" => files
       })
       when is_binary(id) and is_binary(created_at) and is_boolean(include_credentials?) and
              is_integer(file_count) and is_integer(total_bytes) and total_bytes >= 0 and
              is_list(files) do
    cond do
      not String.match?(id, ~r/\Abackup-[A-Za-z0-9_-]{1,128}\z/) ->
        {:error, :invalid_backup_id}

      not valid_created_at?(created_at) ->
        {:error, :invalid_created_at}

      length(files) > @max_files ->
        {:error, :too_many_files}

      file_count != length(files) ->
        {:error, :invalid_file_count}

      true ->
        with {:ok, entries} <- validate_manifest_entries(files),
             true <-
               total_bytes == Enum.reduce(entries, 0, &(&1["bytes"] + &2)) ||
                 {:error, :invalid_total_bytes} do
          {:ok, entries}
        else
          false -> {:error, :invalid_total_bytes}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp validate_manifest(%{"schema" => schema}) when schema != @schema,
    do: {:error, {:unsupported_backup_schema, schema}}

  defp validate_manifest(_), do: {:error, :invalid_manifest}

  defp valid_created_at?(created_at) when byte_size(created_at) <= 40 do
    case DateTime.from_iso8601(created_at) do
      {:ok, _datetime, 0} -> true
      _ -> false
    end
  end

  defp valid_created_at?(_created_at), do: false

  defp validate_manifest_entries(files) do
    Enum.reduce_while(files, {:ok, [], MapSet.new(), 0}, fn entry, {:ok, entries, seen, total} ->
      case validate_manifest_entry(entry) do
        {:ok, normalized} ->
          path = normalized["path"]

          cond do
            MapSet.member?(seen, path) ->
              {:halt, {:error, :duplicate_manifest_path}}

            total + normalized["bytes"] > 1_099_511_627_776 ->
              {:halt, {:error, :backup_too_large}}

            true ->
              {:cont,
               {:ok, [normalized | entries], MapSet.put(seen, path), total + normalized["bytes"]}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries, _seen, _total} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp validate_manifest_entry(
         %{
           "path" => path,
           "bytes" => bytes,
           "sha256" => digest,
           "mode" => mode
         } = entry
       )
       when is_binary(path) and is_integer(bytes) and bytes >= 0 and is_binary(digest) and
              is_integer(mode) do
    cond do
      not safe_relative_path?(path) -> {:error, :unsafe_manifest_path}
      byte_size(path) > @max_path_bytes -> {:error, :manifest_path_too_long}
      not String.match?(digest, ~r/\A[0-9a-f]{64}\z/) -> {:error, :invalid_file_checksum}
      not MapSet.member?(@allowed_restore_modes, mode) -> {:error, :invalid_file_mode}
      true -> {:ok, Map.take(entry, ["path", "bytes", "sha256", "mode"])}
    end
  end

  defp validate_manifest_entry(_), do: {:error, :invalid_manifest_entry}

  defp verify_exact_file_set(bundle, entries) do
    expected = entries |> Enum.map(& &1["path"]) |> MapSet.new()
    data_root = Path.join(bundle, @data_dir)

    with {:ok, actual} <- collect_bundle_files(data_root, "", []),
         actual_set <- MapSet.new(actual),
         true <- MapSet.equal?(expected, actual_set) || {:error, :bundle_file_set_mismatch} do
      :ok
    else
      false -> {:error, :bundle_file_set_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_bundle_files(root, relative, acc) do
    dir = if relative == "", do: root, else: Path.join(root, relative)

    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce_while(names, {:ok, acc}, fn name, {:ok, found} ->
          rel = if relative == "", do: name, else: Path.join(relative, name)
          path = Path.join(root, rel)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory, mode: mode}} ->
              if (mode &&& 0o077) == 0 do
                case collect_bundle_files(root, rel, found) do
                  {:ok, nested} -> {:cont, {:ok, nested}}
                  {:error, reason} -> {:halt, {:error, reason}}
                end
              else
                {:halt, {:error, :unsafe_bundle_permissions}}
              end

            {:ok, %File.Stat{type: :regular, mode: mode}} ->
              if (mode &&& 0o077) == 0 do
                {:cont, {:ok, [rel | found]}}
              else
                {:halt, {:error, :unsafe_bundle_permissions}}
              end

            {:ok, %File.Stat{}} ->
              {:halt, {:error, :unsafe_bundle_entry}}

            {:error, reason} ->
              {:halt, {:error, {:bundle_stat_failed, reason}}}
          end
        end)

      {:error, reason} ->
        {:error, {:bundle_list_failed, reason}}
    end
  end

  defp verify_entries(bundle, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      path = Path.join([bundle, @data_dir, entry["path"]])

      case file_digest(path) do
        {:ok, %{bytes: bytes, sha256: digest}} ->
          if bytes == entry["bytes"] and digest == entry["sha256"] do
            {:cont, :ok}
          else
            {:halt, {:error, :file_checksum_mismatch}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp classify_destination(target, entries) do
    Enum.reduce_while(entries, {:ok, [], []}, fn entry, {:ok, conflicts, identical} ->
      relative = entry["path"]
      destination = Path.join(target, relative)

      case validate_destination_parents(target, relative) do
        :ok ->
          case File.lstat(destination) do
            {:ok, %File.Stat{type: :regular, mode: mode}} ->
              case file_digest(destination) do
                {:ok, %{bytes: bytes, sha256: digest}} ->
                  if bytes == entry["bytes"] and digest == entry["sha256"] and
                       (mode &&& 0o777) == entry["mode"] do
                    {:cont, {:ok, conflicts, [relative | identical]}}
                  else
                    {:cont, {:ok, [relative | conflicts], identical}}
                  end

                {:error, reason} ->
                  {:halt, {:error, reason}}
              end

            {:ok, %File.Stat{}} ->
              {:halt, {:error, :structural_restore_conflict}}

            {:error, :enoent} ->
              {:cont, {:ok, conflicts, identical}}

            {:error, reason} ->
              {:halt, {:error, {:destination_stat_failed, reason}}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, conflicts, identical} ->
        {:ok, Enum.reverse(conflicts), Enum.reverse(identical)}

      error ->
        error
    end
  end

  defp validate_destination_parents(target, relative) do
    relative
    |> Path.dirname()
    |> path_prefixes()
    |> Enum.reduce_while(:ok, fn prefix, :ok ->
      path = Path.join(target, prefix)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:ok, %File.Stat{}} -> {:halt, {:error, :structural_restore_conflict}}
        {:error, reason} -> {:halt, {:error, {:destination_stat_failed, reason}}}
      end
    end)
  end

  defp path_prefixes("."), do: []

  defp path_prefixes(path) do
    path
    |> Path.split()
    |> Enum.reduce({[], []}, fn segment, {parts, prefixes} ->
      next = parts ++ [segment]
      {next, [Path.join(next) | prefixes]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp authorize_conflicts([], _overwrite?), do: :ok
  defp authorize_conflicts(_conflicts, true), do: :ok

  defp authorize_conflicts(conflicts, false),
    do: {:error, {:restore_conflicts, length(conflicts)}}

  defp stage_restore(bundle, target, entries, identical) do
    stage = target <> ".restore.partial.#{unique_suffix()}"
    identical = MapSet.new(identical)

    result =
      try do
        with :ok <- mkdir_p_private(stage),
             :ok <- copy_restore_entries(bundle, stage, entries, identical) do
          {:ok, stage}
        end
      catch
        kind, reason -> {:error, {:restore_stage_failed, kind, reason}}
      end

    case result do
      {:ok, ^stage} ->
        result

      {:error, _reason} ->
        remove_partial(stage)
        result
    end
  end

  defp copy_restore_entries(bundle, stage, entries, identical) do
    entries
    |> Enum.reject(&MapSet.member?(identical, &1["path"]))
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      source = Path.join([bundle, @data_dir, entry["path"]])
      destination = Path.join(stage, entry["path"])

      with :ok <- mkdir_p_private(Path.dirname(destination)),
           {:ok, digest} <- stream_copy_and_digest(source, destination),
           true <- digest == entry["sha256"] || {:error, :file_checksum_mismatch},
           :ok <- chmod_and_sync(destination, entry["mode"]) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :file_checksum_mismatch}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_restore(stage, target, manifest, manifest_digest, conflicts, identical) do
    rollback = target <> ".pre-restore.#{manifest["id"]}"
    entries = manifest["files"]
    identical_set = MapSet.new(identical)
    install_entries = Enum.reject(entries, &MapSet.member?(identical_set, &1["path"]))

    try do
      with :ok <- ensure_absent(rollback),
           :ok <- mkdir_p_private(rollback),
           {:ok, moved} <- move_conflicts_to_rollback(target, rollback, conflicts) do
        case install_staged_files(stage, target, install_entries) do
          {:ok, installed} ->
            receipt = %{
              "schema" => 1,
              "backup_id" => manifest["id"],
              "manifest_sha256" => manifest_digest,
              "target" => target,
              "restored_at" =>
                DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
              "overwritten_count" => length(moved),
              "restored_count" => length(installed),
              "identical_count" => length(identical)
            }

            case write_atomic_synced(
                   Path.join(rollback, "restore-receipt.json"),
                   Jason.encode!(receipt, pretty: true) <> "\n",
                   0o600
                 ) do
              :ok ->
                remove_partial(stage)

                rollback_path = if moved == [], do: nil, else: rollback
                if moved == [], do: remove_partial(rollback)

                {:ok,
                 %{
                   backup_id: manifest["id"],
                   restored_count: length(installed),
                   identical_count: length(identical),
                   overwritten_count: length(moved),
                   rollback_path: rollback_path,
                   target: target,
                   verified: true
                 }}

              {:error, reason} ->
                restore_apply_error(reason, target, rollback, moved, installed)
            end

          {:error, {:install_failed, reason, installed}} ->
            restore_apply_error(reason, target, rollback, moved, installed)
        end
      else
        {:error, {:apply_failed, reason, moved, installed}} ->
          restore_apply_error(reason, target, rollback, moved, installed)

        {:error, reason} ->
          {:error, reason}
      end
    after
      remove_partial(stage)
    end
  end

  defp move_conflicts_to_rollback(target, rollback, conflicts) do
    Enum.reduce_while(conflicts, {:ok, []}, fn relative, {:ok, moved} ->
      source = Path.join(target, relative)
      destination = Path.join(rollback, relative)

      with :ok <- mkdir_p_private(Path.dirname(destination)),
           :ok <- File.rename(source, destination) do
        {:cont, {:ok, [relative | moved]}}
      else
        {:error, reason} -> {:halt, {:error, {:apply_failed, reason, moved, []}}}
      end
    end)
  end

  defp install_staged_files(stage, target, entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, installed} ->
      relative = entry["path"]
      source = Path.join(stage, relative)
      destination = Path.join(target, relative)

      with :ok <- mkdir_p_private(Path.dirname(destination)),
           :ok <- File.rename(source, destination),
           :ok <- sync_dir(Path.dirname(destination)) do
        {:cont, {:ok, [relative | installed]}}
      else
        {:error, reason} ->
          {:halt, {:error, {:install_failed, reason, installed}}}
      end
    end)
  end

  defp rollback_restore(target, rollback, moved, installed) do
    removal_errors =
      Enum.reduce(installed, 0, fn relative, errors ->
        case File.rm(Path.join(target, relative)) do
          :ok -> errors
          {:error, :enoent} -> errors
          {:error, _reason} -> errors + 1
        end
      end)

    restore_errors =
      Enum.reduce(moved, 0, fn relative, errors ->
        source = Path.join(rollback, relative)
        destination = Path.join(target, relative)

        result =
          with :ok <- mkdir_p_private(Path.dirname(destination)),
               :ok <- File.rename(source, destination),
               :ok <- sync_dir(Path.dirname(destination)) do
            :ok
          end

        case result do
          :ok -> errors
          {:error, _reason} -> errors + 1
        end
      end)

    case removal_errors + restore_errors do
      0 ->
        remove_partial(rollback)
        :ok

      count ->
        {:error, {:rollback_incomplete, count, rollback}}
    end
  end

  defp restore_apply_error(reason, target, rollback, moved, installed) do
    case rollback_restore(target, rollback, moved, installed) do
      :ok -> {:error, reason}
      {:error, rollback_reason} -> {:error, {:restore_apply_and_rollback_failed, rollback_reason}}
    end
  end

  defp validate_restore_confirmation(_target, _digest, false, _confirmation, _expected),
    do: :ok

  defp validate_restore_confirmation(target, digest, true, confirmation, expected)
       when is_binary(confirmation) and is_binary(expected) do
    calculated = overwrite_confirmation(digest, target)

    if secure_equal?(confirmation, calculated) and secure_equal?(expected, calculated) do
      :ok
    else
      {:error, :restore_confirmation_mismatch}
    end
  end

  defp validate_restore_confirmation(_target, _digest, true, _confirmation, _expected),
    do: {:error, :restore_confirmation_required}

  defp validate_source(source) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :source_not_directory}
      {:error, :enoent} -> {:error, :source_not_found}
      {:error, reason} -> {:error, {:source_stat_failed, reason}}
    end
  end

  defp validate_restore_target(target) do
    case File.lstat(target) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :unsafe_restore_target}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:restore_target_stat_failed, reason}}
    end
  end

  defp validate_output(source, output) do
    cond do
      output == source -> {:error, :output_is_source}
      String.starts_with?(source, output <> "/") -> {:error, :output_contains_source}
      output_inside_unexcluded_source?(source, output) -> {:error, :output_inside_source}
      true -> :ok
    end
  end

  defp output_inside_unexcluded_source?(source, output) do
    backups_root = Path.join(source, "backups")

    String.starts_with?(output, source <> "/") and output != backups_root and
      not String.starts_with?(output, backups_root <> "/")
  end

  defp verify_bundle_root(bundle) do
    case File.lstat(bundle) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{}} -> {:error, :backup_not_directory}
      {:error, :enoent} -> {:error, :backup_not_found}
      {:error, reason} -> {:error, {:backup_stat_failed, reason}}
    end
  end

  defp ensure_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp ensure_absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :path_exists}
      {:error, reason} -> {:error, {:stat_failed, reason}}
    end
  end

  defp with_lock(root, fun) when is_function(fun, 0) do
    lock = Path.join(Path.dirname(root), ".#{Path.basename(root)}.backup-restore.lock")

    with :ok <- File.mkdir_p(Path.dirname(lock)),
         {:ok, io} <- File.open(lock, [:write, :exclusive, :binary]) do
      try do
        :ok = IO.binwrite(io, "pid=#{System.pid()}\n")
        :ok = :file.sync(io)
        File.chmod(lock, 0o600)
        fun.()
      after
        File.close(io)
        File.rm(lock)
      end
    else
      {:error, :eexist} -> {:error, :backup_restore_locked}
      {:error, reason} -> {:error, {:lock_failed, reason}}
    end
  end

  defp source_root(opts), do: Paths.home_state_dir(paths_opts(opts)) |> Path.expand()

  defp target_root(opts) do
    case Keyword.get(opts, :target) do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> source_root(opts)
    end
  end

  defp paths_opts(opts), do: Keyword.get(opts, :paths_opts, [])

  defp exclusion_reason(relative, include_credentials?) do
    parts = Path.split(relative)
    top = List.first(parts)
    base = Path.basename(relative)

    cond do
      MapSet.member?(@always_excluded_roots, top) ->
        "runtime_or_generated"

      relative == ".backup-restore.lock" ->
        "runtime_lock"

      String.starts_with?(base, "support-bundle-") ->
        "support_bundle"

      String.ends_with?(base, ".pid") or String.ends_with?(base, ".sock") ->
        "runtime_state"

      not include_credentials? and MapSet.member?(@credential_files, relative) ->
        "credential_material"

      not include_credentials? and top == "nodes" and Enum.at(parts, 1) == "execution" ->
        "credential_material"

      true ->
        nil
    end
  end

  defp exclusion_descriptions(include_credentials?) do
    base = [
      "installed versions and launcher symlinks",
      "runtime pid/socket/lock state",
      "temporary files, caches, logs, support bundles, and prior backups",
      "restore rollback directories",
      "symlinks and special files",
      "platform keychain contents",
      "project-local .lemon directories"
    ]

    if include_credentials? do
      base
    else
      base ++ ["local cookie/env/master-key and execution-node credential files"]
    end
  end

  defp increment_excluded(excluded, reason), do: Map.update(excluded, reason, 1, &(&1 + 1))

  defp source_restore_mode(mode) do
    owner_bits = mode &&& 0o700

    if MapSet.member?(@allowed_restore_modes, owner_bits),
      do: {:ok, owner_bits},
      else: {:error, :unsupported_source_file_mode}
  end

  defp mkdir_p_private(path) do
    path = Path.expand(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :unsafe_directory_path}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        with :ok <- if(parent == path, do: :ok, else: mkdir_p_private(parent)),
             :ok <- make_private_dir(path) do
          :ok
        end

      {:error, reason} ->
        {:error, {:directory_stat_failed, reason}}
    end
  end

  defp make_private_dir(path) do
    case File.mkdir(path) do
      :ok ->
        case File.chmod(path, 0o700) do
          :ok -> sync_dir(Path.dirname(path))
          {:error, reason} -> {:error, {:chmod_failed, reason}}
        end

      {:error, :eexist} ->
        mkdir_p_private(path)

      {:error, reason} ->
        {:error, {:mkdir_failed, reason}}
    end
  end

  defp bounded_read(path, max_bytes) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= max_bytes || {:error, :manifest_too_large},
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      {:ok, %File.Stat{}} -> {:error, :unsafe_manifest_file}
      false -> {:error, :manifest_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_private_bundle_permissions(bundle) do
    required = [
      bundle,
      Path.join(bundle, @data_dir),
      Path.join(bundle, @manifest),
      Path.join(bundle, @manifest_checksum)
    ]

    Enum.reduce_while(required, :ok, fn path, :ok ->
      if private_path?(path) do
        {:cont, :ok}
      else
        {:halt, {:error, :unsafe_bundle_permissions}}
      end
    end)
  end

  defp private_path?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{mode: mode}} -> (mode &&& 0o077) == 0
      _ -> false
    end
  end

  defp file_digest(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        hash =
          path
          |> File.stream!([], @copy_chunk_bytes)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, %{bytes: size, sha256: hash}}

      {:ok, %File.Stat{}} ->
        {:error, :unsafe_bundle_entry}

      {:error, reason} ->
        {:error, {:digest_failed, reason}}
    end
  rescue
    error -> {:error, {:digest_failed, Exception.message(error)}}
  end

  defp manifest_summary(path, manifest) do
    %{
      id: manifest["id"],
      path: Path.expand(path),
      created_at: manifest["created_at"],
      contract_version: manifest["contract_version"],
      file_count: manifest["file_count"],
      total_bytes: manifest["total_bytes"],
      includes_credentials: manifest["include_credentials"] == true,
      contents_returned: false,
      secret_values_returned: false
    }
  end

  defp safe_relative_path?(path) do
    parts = Path.split(path)

    path != "" and Path.type(path) == :relative and byte_size(path) <= @max_path_bytes and
      not String.contains?(path, ["\\", <<0>>]) and parts != [] and
      Enum.all?(parts, &(&1 not in ["", ".", ".."])) and Path.join(parts) == path
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp overwrite_confirmation(manifest_digest, target) do
    sha256("lemon-backup-restore-v1\0" <> manifest_digest <> "\0" <> Path.expand(target))
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {a, b}, acc -> acc ||| bxor(a, b) end) == 0
  end

  defp secure_equal?(_, _), do: false

  defp default_bundle_name do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    "lemon-backup-#{timestamp}-#{unique_suffix()}.lemonbackup"
  end

  defp unique_suffix do
    random = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "#{System.system_time(:millisecond)}-#{random}"
  end

  defp remove_partial(path) do
    if is_binary(path) and String.contains?(Path.basename(path), [".partial.", ".pre-restore."]) do
      File.rm_rf(path)
    end

    :ok
  end

  defp write_atomic_synced(path, bytes, mode) do
    tmp = path <> ".tmp.#{unique_suffix()}"

    try do
      with :ok <- write_synced(tmp, bytes),
           :ok <- if(is_integer(mode), do: chmod_and_sync(tmp, mode), else: :ok),
           :ok <- File.rename(tmp, path),
           :ok <- sync_dir(Path.dirname(path)) do
        :ok
      end
    after
      File.rm(tmp)
    end
  end

  defp chmod_and_sync(path, mode) do
    with :ok <- File.chmod(path, mode),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        :file.sync(io)
      after
        File.close(io)
      end
    end
  end

  # Directory fsync is supported on the Unix filesystems Lemon targets. Some
  # filesystems/OTP builds reject opening a directory; in that case the file
  # itself is still synced and the atomic rename remains the compatibility
  # floor.
  defp sync_dir(path) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, io} ->
        _ = :file.sync(io)
        :ok = :file.close(io)
        :ok

      {:error, _unsupported} ->
        :ok
    end
  end

  # Errors and manifests expose only relative paths; never return the absolute
  # user-state source path in metadata or error tuples.
  defp safe_path(""), do: "."
  defp safe_path(relative), do: relative
end
