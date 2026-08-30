defmodule CodingAgent.PrivateTmp do
  @moduledoc """
  Private-at-creation temporary files and directories.

  Every secret-bearing temporary object the coding agent creates — one-shot
  and persistent `execute_code` workspaces, per-cell RPC bridges, Python
  session workspaces, spilled kernel output, and RPC responses — is reserved
  through this single boundary.

  Neither `File.mkdir/1` nor `File.open/2` can create an object with explicit
  owner-only permissions: OTP creates directories `0777` and files `0666`,
  masked only by the inherited umask, so restricting them requires a
  chmod-after-create window during which a world-traversable directory or a
  world-readable file is observable. This module instead drives an absolute
  `mktemp` executable directly — never through a shell, never with `-u` —
  which reserves each object atomically with owner-only permissions, and then
  validates the reservation before handing it out:

    * the printed result is a single absolute path directly inside the
      expected parent with the expected prefix,
    * `File.lstat/1` shows the expected type (`:directory` for reservations
      made with `-d`, `:regular` otherwise), and
    * the permission bits are exactly `0700` for directories and `0600` for
      files.

  A reservation that fails a check is removed — only once containment is
  proven, so a hostile `mktemp` output can never make this module delete a
  path it does not own — and the failure is returned as `{:error, reason}`.
  Callers must fail closed: there is deliberately no chmod fallback and no
  open-permission fallback, because the inability to reserve exact modes is a
  setup error, not permission to expose content.

  This boundary requires a compatible absolute `mktemp` (resolved once from
  PATH and retained) and a trusted local filesystem beneath
  `System.tmp_dir!()` (NFS is not supported). It fails closed when those
  guarantees cannot be established.
  """

  import Bitwise

  @dir_mode 0o700
  @file_mode 0o600
  @rand String.duplicate("X", 10)

  # Python REPL output spill files are part of a completed-cell result, so
  # they cannot be removed at cell teardown. Reap them from the only point
  # that has already validated the cached staging root.
  @spill_prefix "pi-python-repl-"
  @spill_ttl_seconds 24 * 60 * 60
  @spill_sweep_limit 1_000

  @root_prefix "lemon-private"
  @root_key {__MODULE__, :root}
  @root_lock {__MODULE__, :root_lock}
  @spill_sweep_key {__MODULE__, :spill_sweep_at}
  @spill_sweep_lock {__MODULE__, :spill_sweep_lock}
  @spill_continuations_key {__MODULE__, :spill_sweep_continuations}
  @live_spills_key {__MODULE__, :live_spills}
  @live_spills_lock {__MODULE__, :live_spills_lock}
  @stale_root_sweep_key {__MODULE__, :stale_root_sweep_done}
  @stale_roots_key {__MODULE__, :stale_roots}
  @stale_root_sweep_lock {__MODULE__, :stale_root_sweep_lock}
  @mktemp_key {__MODULE__, :mktemp}

  @owner_marker ".lemon-owner"
  @remove_tree_limit 10_000

  @typep reservation :: {:ok, String.t()} | {:error, term()}

  ## Shared private root

  @doc """
  The application-private staging root shared by all reservations.

  Created on first use as `<tmpdir>/#{@root_prefix}-XXXXXXXXXX` (`0700`,
  validated) and cached for the node's lifetime in `:persistent_term/0`.
  Concurrent first calls are serialized, so every caller receives the same
  root. A cached root that was removed or no longer validates is replaced on
  the next call. A successful root lookup also opportunistically reaps up to
  #{@spill_sweep_limit} entries from expired Python REPL output spills once
  per 24-hour window; the reaper is best-effort and never affects a root
  reservation. The first lookup on a node discovers validated sibling roots
  left by prior nodes. A reused OS PID can conservatively postpone cleanup of
  an otherwise stale sibling until a later node boot.
  """
  @spec root() :: reservation()
  def root do
    case cached_root() do
      {:ok, path} ->
        finish_root_lookup(path)

      :error ->
        create_root()
    end
  end

  defp create_root do
    case with_node_lock(@root_lock, fn ->
           case cached_root() do
             {:ok, path} ->
               {:ok, path}

             :error ->
               case reserve(System.tmp_dir!(), @root_prefix, :directory, []) do
                 {:ok, path} ->
                   case write_owner_marker(path) do
                     :ok ->
                       :persistent_term.put(@root_key, path)
                       {:ok, path}

                     {:error, _reason} = error ->
                       File.rm_rf(path)
                       error
                   end

                 {:error, _reason} = error ->
                   error
               end
           end
         end) do
      {:ok, path} ->
        finish_root_lookup(path)

      {:error, _reason} = error ->
        error
    end
  end

  defp cached_root do
    case :persistent_term.get(@root_key, nil) do
      path when is_binary(path) ->
        with :ok <- validate_shape(path, System.tmp_dir!(), @root_prefix),
             :ok <- confirm(path, :directory) do
          {:ok, path}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp finish_root_lookup(path) do
    maybe_discover_stale_roots(path)
    maybe_reap_spills(path)
    {:ok, path}
  end

  ## Reservations

  @doc """
  Reserves a fresh private directory (exactly `0700`) directly inside `parent`.

  `prefix` names the reservation: the final component is `<prefix>-XXXXXXXXXX`
  with the trailing X's replaced by unguessable characters.

  The `:mktemp` option is a test seam that overrides the executable used for
  this reservation; `:runner` replaces the whole invocation with
  `fun(argv) -> {output, exit_status}`.
  """
  @spec reserve_dir(String.t(), String.t(), keyword()) :: reservation()
  def reserve_dir(parent, prefix, opts \\ [])
      when is_binary(parent) and is_binary(prefix) and is_list(opts) do
    reserve(parent, prefix, :directory, opts)
  end

  @doc """
  Reserves a fresh private empty regular file (exactly `0600`) directly inside
  `parent`.

  See `reserve_dir/3` for the prefix and the test seams.
  """
  @spec reserve_file(String.t(), String.t(), keyword()) :: reservation()
  def reserve_file(parent, prefix, opts \\ [])
      when is_binary(parent) and is_binary(prefix) and is_list(opts) do
    reserve(parent, prefix, :regular, opts)
  end

  @doc """
  Writes `contents` to `parent/name` as a private (`0600`) file.

  A random reservation is created exclusively inside `parent`, written through
  a descriptor on the reserved path, and published with a same-directory
  rename, so a partially written file is never visible under the final name
  and a planted symlink at the final name is replaced rather than followed.
  On any failure the reservation is removed and the error returned; nothing is
  left behind.
  """
  @spec write_file(String.t(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write_file(parent, name, contents, opts \\ [])
      when is_binary(parent) and is_binary(name) and is_binary(contents) and is_list(opts) do
    with {:ok, reserved} <- reserve_file(parent, reservation_prefix(name), opts) do
      write_reserved(reserved, Path.join(parent, name), contents)
    end
  end

  @doc """
  Copies `source` into `parent/name` as a private (`0600`) file.

  The destination keeps its reservation's owner-only mode — unlike
  `File.cp/2`, which copies the source's mode bits onto the destination.
  Failures return the raw POSIX reason (for example `:enoent` for a missing
  source) and remove the reservation.
  """
  @spec copy_file(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def copy_file(source, parent, name, opts \\ [])
      when is_binary(source) and is_binary(parent) and is_binary(name) and is_list(opts) do
    with {:ok, reserved} <- reserve_file(parent, reservation_prefix(name), opts) do
      copy_reserved(source, reserved, Path.join(parent, name))
    end
  end

  @doc false
  @spec register_live_spill(String.t()) :: :ok | {:error, term()}
  def register_live_spill(path) when is_binary(path) do
    try do
      case with_node_lock(@live_spills_lock, fn ->
             live_spills = :persistent_term.get(@live_spills_key, %{})
             :persistent_term.put(@live_spills_key, Map.put(live_spills, path, self()))
             :ok
           end) do
        :ok -> :ok
        other -> {:error, {:live_spill_tracking_failed, other}}
      end
    rescue
      error -> {:error, {:live_spill_tracking_failed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:live_spill_tracking_failed, {kind, reason}}}
    end
  end

  @doc false
  @spec unregister_live_spill(String.t()) :: :ok | {:error, term()}
  def unregister_live_spill(path) when is_binary(path) do
    try do
      case with_node_lock(@live_spills_lock, fn ->
             live_spills = :persistent_term.get(@live_spills_key, %{})
             remaining = Map.delete(live_spills, path)

             if map_size(remaining) == 0 do
               :persistent_term.erase(@live_spills_key)
             else
               :persistent_term.put(@live_spills_key, remaining)
             end

             :ok
           end) do
        :ok -> :ok
        other -> {:error, {:live_spill_tracking_failed, other}}
      end
    rescue
      error -> {:error, {:live_spill_tracking_failed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:live_spill_tracking_failed, {kind, reason}}}
    end
  end

  ## Internals

  # The one bounded batch per window is shared by the current root and stale
  # roots. The current root always receives the first part of the budget; at
  # most one stale root receives any remainder, so abandoned roots cannot
  # multiply a normal root lookup's filesystem work.
  defp maybe_reap_spills(root) do
    if sweep_due?(System.monotonic_time(:second)) do
      try do
        with_node_lock(@spill_sweep_lock, fn ->
          now = System.monotonic_time(:second)

          if sweep_due?(now) do
            :persistent_term.put(@spill_sweep_key, now)
            current_count = reap_expired_spills(root, @spill_sweep_limit)
            remaining = @spill_sweep_limit - current_count

            if remaining > 0 do
              reap_one_stale_root(remaining)
            end
          end
        end)
      rescue
        _error -> :ok
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  defp maybe_discover_stale_roots(root) do
    if :persistent_term.get(@stale_root_sweep_key, false) != true do
      try do
        with_node_lock(@stale_root_sweep_lock, fn ->
          if :persistent_term.get(@stale_root_sweep_key, false) != true do
            :persistent_term.put(@stale_root_sweep_key, true)
            discover_stale_roots(root)
          end
        end)
      rescue
        _error -> :ok
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  defp sweep_due?(now) do
    case :persistent_term.get(@spill_sweep_key, nil) do
      last_sweep when is_integer(last_sweep) -> now - last_sweep >= @spill_ttl_seconds
      _ -> true
    end
  end

  # `File.ls/1` materializes a directory listing, but only this bounded batch
  # receives `lstat`/removal work. The unprocessed names persist by root and
  # are resumed on the next sweep instead of repeatedly stranding entries
  # behind the same leading batch.
  defp reap_expired_spills(root, limit) do
    case next_spill_batch(root, limit) do
      {:ok, names} ->
        cutoff = System.system_time(:second) - @spill_ttl_seconds
        Enum.each(names, &remove_expired_spill(root, &1, cutoff))
        length(names)

      _ ->
        0
    end
  end

  defp next_spill_batch(root, limit) do
    continuations = :persistent_term.get(@spill_continuations_key, %{})

    case Map.pop(continuations, root) do
      {nil, _remaining_continuations} ->
        case File.ls(root) do
          {:ok, names} -> split_spill_batch(root, names, continuations, limit)
          {:error, reason} -> {:error, reason}
        end

      {names, remaining_continuations} ->
        split_spill_batch(root, names, remaining_continuations, limit)
    end
  end

  defp split_spill_batch(root, names, continuations, limit) do
    {batch, remainder} = Enum.split(names, limit)

    updated_continuations =
      if remainder == [] do
        continuations
      else
        Map.put(continuations, root, remainder)
      end

    if map_size(updated_continuations) == 0 do
      :persistent_term.erase(@spill_continuations_key)
    else
      :persistent_term.put(@spill_continuations_key, updated_continuations)
    end

    {:ok, batch}
  end

  defp discover_stale_roots(current_root) do
    tmp_dir = System.tmp_dir!()

    roots =
      case File.ls(tmp_dir) do
        {:ok, names} ->
          Enum.reduce(names, [], fn name, roots ->
            root = Path.join(tmp_dir, name)

            if root != current_root and
                 String.starts_with?(Path.basename(name), @root_prefix <> "-") and
                 stale_root?(root, tmp_dir) do
              [root | roots]
            else
              roots
            end
          end)
          |> Enum.reverse()

        {:error, _reason} ->
          []
      end

    if roots == [] do
      :persistent_term.erase(@stale_roots_key)
    else
      :persistent_term.put(@stale_roots_key, roots)
    end
  end

  defp stale_root?(root, tmp_dir) do
    with :ok <- validate_shape(root, tmp_dir, @root_prefix),
         :ok <- confirm(root, :directory),
         {:ok, _marker, pid} <- owner_marker(root),
         false <- os_pid_alive?(pid) do
      true
    else
      _ -> false
    end
  end

  defp reap_one_stale_root(limit) do
    case :persistent_term.get(@stale_roots_key, []) do
      [stale_root | remaining] ->
        put_stale_roots(remaining)

        if reap_stale_root(stale_root, System.tmp_dir!(), limit) == :continue do
          enqueue_stale_root(stale_root)
        end

      _ ->
        :ok
    end
  end

  defp enqueue_stale_root(root) do
    roots = :persistent_term.get(@stale_roots_key, [])
    put_stale_roots(roots ++ [root])
  end

  defp put_stale_roots([]), do: :persistent_term.erase(@stale_roots_key)
  defp put_stale_roots(roots), do: :persistent_term.put(@stale_roots_key, roots)

  defp reap_stale_root(root, tmp_dir, limit) do
    with :ok <- validate_shape(root, tmp_dir, @root_prefix),
         :ok <- confirm(root, :directory),
         {:ok, marker, pid} <- owner_marker(root),
         false <- os_pid_alive?(pid) do
      reap_expired_spills(root, limit)

      if has_spill_continuation?(root) do
        :continue
      else
        remove_owner_marker_if_empty(root, marker)
        :done
      end
    else
      _ -> :done
    end
  end

  defp has_spill_continuation?(root) do
    :persistent_term.get(@spill_continuations_key, %{})
    |> Map.has_key?(root)
  end

  defp remove_owner_marker_if_empty(root, marker) do
    if File.ls(root) == {:ok, [@owner_marker]} do
      _ = File.rm(marker)
      _ = File.rmdir(root)
    end
  end

  defp owner_marker(root) do
    marker = Path.join(root, @owner_marker)

    with :ok <- confirm(marker, :regular),
         {:ok, contents} <- File.read(marker),
         [node_name, pid] <- String.split(String.trim(contents), "\n"),
         true <- node_name != "",
         {parsed_pid, ""} when parsed_pid > 0 <- Integer.parse(pid) do
      {:ok, marker, pid}
    else
      _ -> :error
    end
  end

  defp os_pid_alive?(pid) do
    case System.find_executable("kill") do
      nil ->
        true

      kill ->
        try do
          match?({_output, 0}, System.cmd(kill, ["-0", pid], stderr_to_stdout: true))
        rescue
          _error -> true
        end
    end
  end

  defp remove_expired_spill(root, name, cutoff) do
    if String.starts_with?(Path.basename(name), @spill_prefix) do
      path = Path.join(root, name)

      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :regular, mtime: modified_at}} when modified_at < cutoff ->
          if not live_spill?(path), do: _ = File.rm(path)
          :ok

        _ ->
          :ok
      end
    end
  end

  defp live_spill?(path) do
    case :persistent_term.get(@live_spills_key, %{}) do
      %{^path => owner} when is_pid(owner) ->
        if Process.alive?(owner) do
          true
        else
          _ = unregister_live_spill(path)
          false
        end

      _ ->
        false
    end
  end

  defp write_owner_marker(root) do
    write_file(root, @owner_marker, "#{node()}\n#{System.pid()}\n")
  end

  defp with_node_lock(resource, fun) do
    :global.trans({resource, self()}, fun, [node()])
  end

  # The printed reservation is only trusted once it is a single absolute path
  # directly inside the parent we named, carrying the prefix we asked for.
  # Until then nothing may be deleted on its behalf.
  defp validate_shape(path, parent, prefix) do
    # `System.tmp_dir!/0` includes a trailing separator on macOS, while
    # `Path.dirname/1` returns the same directory without it. Compare expanded
    # lexical paths so the containment check remains exact on both shapes.
    parent = Path.expand(parent)

    if is_binary(path) and Path.type(path) == :absolute and
         Path.dirname(path) == parent and String.starts_with?(Path.basename(path), prefix) do
      :ok
    else
      {:error, {:invalid_reservation_path, path}}
    end
  end

  defp confirm(path, kind) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type, mode: mode}} ->
        perms = mode &&& 0o777

        if type == kind and perms == expected_mode(kind) do
          :ok
        else
          {:error, {:insecure_reservation, type, perms}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reserve(parent, prefix, kind, opts) do
    template = Path.join(parent, prefix <> "-" <> @rand)

    with {:ok, path} <- run_mktemp(template, kind == :directory, opts),
         :ok <- validate_shape(path, parent, prefix) do
      case confirm(path, kind) do
        :ok ->
          {:ok, path}

        {:error, reason} ->
          # Containment is proven, so the object is ours to delete.
          discard(path, kind)
          {:error, reason}
      end
    end
  end

  defp expected_mode(:directory), do: @dir_mode
  defp expected_mode(:regular), do: @file_mode

  defp discard(path, :directory), do: File.rm_rf(path)
  defp discard(path, :regular), do: File.rm(path)

  # `:runner` is a deterministic test seam: `fun(argv) -> {output,
  # exit_status}`, replacing the real mktemp invocation. Whatever it returns
  # flows through the exact same validation as the real executable.
  defp run_mktemp(template, dir?, opts) do
    argv = if dir?, do: ["-d", template], else: [template]

    case Keyword.fetch(opts, :runner) do
      {:ok, runner} when is_function(runner, 1) ->
        classify(runner.(argv))

      {:ok, other} ->
        {:error, {:mktemp_bad_runner, other}}

      :error ->
        case cmd_mktemp(argv, opts) do
          {output, status} when is_binary(output) and is_integer(status) ->
            classify({output, status})

          # mktemp-executable resolution/rescue failures pass through as-is.
          {:error, _reason} = error ->
            error
        end
    end
  end

  defp classify({output, 0}) when is_binary(output), do: single_absolute_path(output)

  defp classify({output, status}) when is_binary(output) and is_integer(status),
    do: {:error, {:mktemp_failed, status, String.trim_trailing(output)}}

  defp classify(other), do: {:error, {:mktemp_bad_result, other}}

  defp cmd_mktemp(argv, opts) do
    with {:ok, mktemp} <- mktemp_exec(opts) do
      try do
        System.cmd(mktemp, argv, stderr_to_stdout: true)
      rescue
        error ->
          {:error, {:mktemp_unavailable, Exception.message(error)}}
      end
    end
  end

  defp single_absolute_path(output) do
    case output |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [path] ->
        if Path.type(path) == :absolute do
          {:ok, path}
        else
          {:error, {:mktemp_relative_path, path}}
        end

      lines ->
        {:error, {:mktemp_unexpected_output, lines}}
    end
  end

  defp mktemp_exec(opts) do
    case Keyword.get(opts, :mktemp) do
      mktemp when is_binary(mktemp) ->
        {:ok, mktemp}

      nil ->
        case :persistent_term.get(@mktemp_key, nil) do
          mktemp when is_binary(mktemp) ->
            {:ok, mktemp}

          nil ->
            case System.find_executable("mktemp") do
              mktemp when is_binary(mktemp) ->
                :persistent_term.put(@mktemp_key, mktemp)
                {:ok, mktemp}

              nil ->
                {:error, :mktemp_not_found}
            end
        end
    end
  end

  defp write_reserved(reserved, final, contents) do
    case File.open(reserved, [:write, :binary]) do
      {:ok, io} ->
        result =
          with :ok <- IO.binwrite(io, contents) do
            File.rename(reserved, final)
          end

        _ = File.close(io)
        if match?({:error, _}, result), do: _ = File.rm(reserved)
        result

      {:error, reason} ->
        _ = File.rm(reserved)
        {:error, reason}
    end
  end

  defp copy_reserved(source, reserved, final) do
    case File.open(source, [:read, :binary]) do
      {:ok, source_io} ->
        result = copy_into(source_io, reserved, final)
        _ = File.close(source_io)
        result

      {:error, reason} ->
        _ = File.rm(reserved)
        {:error, reason}
    end
  end

  defp copy_into(source_io, reserved, final) do
    case File.open(reserved, [:write, :binary]) do
      {:ok, dest_io} ->
        result =
          case :file.copy(source_io, dest_io) do
            {:ok, _bytes} -> File.rename(reserved, final)
            {:error, reason} -> {:error, reason}
          end

        _ = File.close(dest_io)
        if match?({:error, _}, result), do: _ = File.rm(reserved)
        result

      {:error, reason} ->
        _ = File.rm(reserved)
        {:error, reason}
    end
  end

  # Hidden, name-derived reservation prefix: publishing `res-3.json` reserves
  # `.res-3-XXXXXXXXXX` first, so incomplete reservations never collide with
  # protocol globs such as `req-*.json` or `*.tmp`.
  defp reservation_prefix(name), do: "." <> Path.rootname(name) <> "-"

  ## Bounded tree removal

  @doc """
  Removes a file, link, or directory tree with bounded work.

  `File.rm_rf/1` gives callers no bound: a hostile or runaway script that
  planted an arbitrarily deep or wide tree (an `execute_code` workspace or
  bridge base is writable by the script that runs in it) can make teardown
  enumerate and delete without limit, stalling the owning process. This
  helper performs an iterative post-order traversal that never follows
  symlinks and visits at most `:max_entries` entries (default
  `#{@remove_tree_limit}`).

  Returns `:complete` when the whole tree was removed and `:truncated` when
  the budget ran out first — in that case the remainder is left in place
  (owner-only, inside the private root) and the caller should log; leftover
  `lemon-private-*` roots are candidates for the boot-time stale-root sweep
  on a later node. Per-entry errors (races with a still-writing script) are
  ignored: removal is best-effort, exactly like `File.rm_rf/1`, but bounded.

  `File.ls/1` materializes each directory's listing; the cap bounds entry
  visits (`lstat`/delete work), not the directory enumeration itself.
  """
  @spec remove_tree(String.t(), keyword()) :: :complete | :truncated
  def remove_tree(path, opts \\ []) when is_binary(path) and is_list(opts) do
    limit = Keyword.get(opts, :max_entries, @remove_tree_limit)
    walk_tree([path], limit)
  end

  defp walk_tree([], _budget), do: :complete
  defp walk_tree(_stack, budget) when budget <= 0, do: :truncated

  defp walk_tree([{:dir, path} | rest], budget) do
    _ = File.rmdir(path)
    walk_tree(rest, budget - 1)
  end

  defp walk_tree([path | rest], budget) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        children =
          case File.ls(path) do
            {:ok, names} -> Enum.map(names, &Path.join(path, &1))
            {:error, _reason} -> []
          end

        # Re-push the directory itself after its children so it is rmdir'd
        # post-order; the marker cannot collide with a real child because it
        # is tagged.
        walk_tree(children ++ [{:dir, path} | rest], budget - 1)

      {:ok, %File.Stat{}} ->
        _ = File.rm(path)
        walk_tree(rest, budget - 1)

      {:error, _reason} ->
        walk_tree(rest, budget - 1)
    end
  end
end
