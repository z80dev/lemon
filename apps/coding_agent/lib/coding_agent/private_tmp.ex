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

  This boundary is explicitly local GNU/Linux: it requires an absolute
  `mktemp` (resolved once from PATH and retained), a trusted local filesystem
  beneath `System.tmp_dir!()` (NFS is not supported), and it fails closed on
  any other platform.
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
  @spill_sweep_key {__MODULE__, :spill_sweep_at}
  @spill_sweep_lock {__MODULE__, :spill_sweep_lock}
  @mktemp_key {__MODULE__, :mktemp}

  @typep reservation :: {:ok, String.t()} | {:error, term()}

  ## Shared private root

  @doc """
  The application-private staging root shared by all reservations.

  Created on first use as `<tmpdir>/#{@root_prefix}-XXXXXXXXXX` (`0700`,
  validated) and cached for the node's lifetime in `:persistent_term/0`.
  Concurrent first calls may each create a root; every root is private, so the
  race is benign — only the cached one is reused, and a cached root that was
  removed or no longer validates is replaced on the next call. A successful
  root lookup also opportunistically reaps up to #{@spill_sweep_limit} expired
  Python REPL output spills once per #{@spill_ttl_seconds / 3600}-hour window;
  the reaper is best-effort and never affects a root reservation.
  """
  @spec root() :: reservation()
  def root do
    case :persistent_term.get(@root_key, nil) do
      nil ->
        create_root()

      path ->
        with :ok <- validate_shape(path, System.tmp_dir!(), @root_prefix),
             :ok <- confirm(path, :directory) do
          maybe_reap_spills(path)
          {:ok, path}
        else
          _ -> create_root()
        end
    end
  end

  defp create_root do
    case reserve(System.tmp_dir!(), @root_prefix, :directory, []) do
      {:ok, path} = ok ->
        :persistent_term.put(@root_key, path)
        maybe_reap_spills(path)
        ok

      {:error, _reason} = error ->
        error
    end
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

  ## Internals

  # This is deliberately attached to `root/0`, rather than output capture:
  # the root is already cached and validated there, and every spill creation
  # obtains it. A persistent-term timestamp is the fast path; the local
  # `:global` lock closes the first-call race so a node runs no more than one
  # sweep per window.
  defp maybe_reap_spills(root) do
    if sweep_due?(System.monotonic_time(:second)) do
      try do
        :global.trans(
          @spill_sweep_lock,
          fn ->
            now = System.monotonic_time(:second)

            if sweep_due?(now) do
              :persistent_term.put(@spill_sweep_key, now)
              reap_expired_spills(root)
            end
          end,
          [node()]
        )
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

  # The root may contain other private reservations. Limit filesystem work per
  # opportunity and inspect only direct children whose basenames match the
  # dedicated REPL spill prefix. `lstat` refuses to follow a planted symlink;
  # `File.rm/1` likewise removes a raced replacement rather than its target.
  defp reap_expired_spills(root) do
    cutoff = System.system_time(:second) - @spill_ttl_seconds

    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.take(@spill_sweep_limit)
        |> Enum.each(&remove_expired_spill(root, &1, cutoff))

      {:error, _reason} ->
        :ok
    end
  end

  defp remove_expired_spill(root, name, cutoff) do
    if String.starts_with?(name, @spill_prefix) do
      path = Path.join(root, name)

      case File.lstat(path, time: :posix) do
        {:ok, %File.Stat{type: :regular, mtime: modified_at}} when modified_at < cutoff ->
          _ = File.rm(path)
          :ok

        _ ->
          :ok
      end
    end
  end

  # The printed reservation is only trusted once it is a single absolute path
  # directly inside the parent we named, carrying the prefix we asked for.
  # Until then nothing may be deleted on its behalf.
  defp validate_shape(path, parent, prefix) do
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
end
