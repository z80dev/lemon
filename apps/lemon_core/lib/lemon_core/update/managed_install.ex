defmodule LemonCore.Update.ManagedInstall do
  @moduledoc """
  Confined filesystem boundary for installer-managed Lemon releases.

  This module owns validation and mutation of the
  `~/.lemon/versions/<version>` layout: exact running/current identity,
  same-directory atomic pointer flips, staged-directory promotion, launcher
  version verification, and bounded retention. It never accepts an arbitrary
  target path; callers supply version identifiers only.
  """

  alias LemonCore.Paths
  alias LemonCore.Update.{Plan, Version}

  @keep_versions 2

  @spec current(keyword()) :: {:ok, String.t()} | {:error, term()}
  def current(opts \\ []) do
    root = Path.expand(release_root(opts))
    versions = Path.expand(versions_dir(opts))

    with true <- String.starts_with?(root, versions <> "/") || {:error, :unsupported_layout},
         {:ok, target} <- File.read_link(Path.join(versions, "current")),
         true <- safe_target?(target) || {:error, :invalid_current_pointer},
         true <-
           root == Path.expand(Path.join(versions, target)) || {:error, :stale_running_release},
         true <- running_version(opts) == target || {:error, :running_version_mismatch},
         :ok <- validate_launcher(launcher(target, opts)) do
      {:ok, target}
    else
      {:error, :enoent} -> {:error, :missing_current_pointer}
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_current_pointer}
    end
  end

  @spec active(keyword()) :: String.t() | nil
  def active(opts \\ []) do
    case File.read_link(Path.join(versions_dir(opts), "current")) do
      {:ok, target} -> if(safe_target?(target), do: target, else: nil)
      {:error, _reason} -> nil
    end
  end

  @spec launcher(String.t(), keyword()) :: String.t()
  def launcher(version, opts), do: Path.join([versions_dir(opts), version, "bin", "lemon"])

  @spec validate_launcher(String.t()) :: :ok | {:error, term()}
  def validate_launcher(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> :ok
      _ -> {:error, :invalid_release_launcher}
    end
  end

  @spec launcher_sha256(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def launcher_sha256(version, opts) do
    path = launcher(version, opts)

    with :ok <- validate_launcher(path) do
      {:ok, sha256_file(path)}
    end
  end

  @spec verify_active(String.t(), keyword()) :: :ok | {:error, term()}
  def verify_active(version, opts) do
    with ^version <- active(opts),
         path <- launcher(version, opts),
         :ok <- validate_launcher(path),
         :ok <- verify_launcher_version(path, version, opts),
         :ok <- run_active_verifier(version, opts) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :active_version_verification_failed}
    end
  end

  # Test/proof seam for failures that occur after the pointer has moved and
  # after the launcher's ordinary version check succeeds. Production callers
  # do not provide it. Keeping the seam here lets transaction tests prove that
  # Remote restores the exact previous pointer without weakening verification.
  defp run_active_verifier(version, opts) do
    case Keyword.get(opts, :active_verify_fun) do
      fun when is_function(fun, 1) -> fun.(version)
      _ -> :ok
    end
  end

  @spec verify_launcher_version(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def verify_launcher_version(path, version, opts) do
    case Keyword.get(opts, :version_verify_fun) do
      fun when is_function(fun, 2) -> fun.(path, version)
      _ -> run_version_command(path, version, opts)
    end
  end

  @spec promote(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def promote(partial, version, opts) do
    final = Path.join(versions_dir(opts), version)

    cond do
      usable?(final) -> {:ok, final}
      File.exists?(final) -> replace(partial, final)
      true -> rename_into_place(partial, final)
    end
  end

  @spec flip(String.t(), keyword()) :: :ok | {:error, term()}
  def flip(version, opts) do
    if safe_target?(version) do
      dir = versions_dir(opts)
      current = Path.join(dir, "current")
      tmp = Path.join(dir, ".current.tmp.#{os_pid()}")

      try do
        File.rm(tmp)

        with :ok <- File.ln_s(version, tmp),
             :ok <- File.rename(tmp, current) do
          :ok
        else
          {:error, reason} -> {:error, {:symlink_failed, reason}}
        end
      after
        File.rm(tmp)
      end
    else
      {:error, :invalid_version_target}
    end
  end

  @spec restore_after_failed_flip(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def restore_after_failed_flip(previous, attempted, opts) do
    if active(opts) == attempted, do: flip(previous, opts), else: :ok
  end

  @spec prune([String.t()], keyword()) :: :ok
  def prune(protected_versions, opts) do
    dir = versions_dir(opts)

    dir
    |> version_dirs()
    |> Enum.reject(&(&1 in protected_versions))
    |> Enum.sort(&(Version.compare(&1, &2) != :lt))
    |> Enum.drop(@keep_versions)
    |> Enum.each(&File.rm_rf(Path.join(dir, &1)))

    :ok
  end

  @spec versions_dir(keyword()) :: String.t()
  def versions_dir(opts), do: Path.join(Paths.home_state_dir(paths_opts(opts)), "versions")

  defp run_version_command(path, version, opts) do
    task = Task.async(fn -> System.cmd(path, ["version"], stderr_to_stdout: true) end)

    case Task.yield(task, Keyword.get(opts, :version_timeout_ms, 10_000)) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        if String.trim(output) == version, do: :ok, else: {:error, :staged_version_mismatch}

      {:ok, {_output, _status}} ->
        {:error, :staged_version_command_failed}

      {:exit, _reason} ->
        {:error, :staged_version_command_failed}

      nil ->
        {:error, :staged_version_timeout}
    end
  end

  defp replace(partial, final) do
    aside = "#{final}.broken.#{os_pid()}"
    File.rm_rf(aside)

    case File.rename(final, aside) do
      :ok -> swap_in(partial, final, aside)
      {:error, reason} -> {:error, {:rename_failed, reason}}
    end
  end

  defp swap_in(partial, final, aside) do
    case rename_into_place(partial, final) do
      {:ok, dir} ->
        File.rm_rf(aside)
        {:ok, dir}

      {:error, reason} ->
        File.rename(aside, final)
        {:error, reason}
    end
  end

  defp rename_into_place(partial, final) do
    case File.rename(partial, final) do
      :ok -> {:ok, final}
      {:error, reason} -> {:error, {:rename_failed, reason}}
    end
  end

  defp usable?(dir) do
    match?(:ok, validate_launcher(Path.join(dir, "bin/lemon")))
  end

  defp version_dirs(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == "current"))
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.reject(&(String.ends_with?(&1, ".partial") or String.contains?(&1, ".broken.")))
        |> Enum.filter(&(Plan.safe_version?(&1) and File.dir?(Path.join(dir, &1))))

      {:error, _reason} ->
        []
    end
  end

  defp safe_target?(target) when is_binary(target),
    do:
      Path.type(target) == :relative and Path.basename(target) == target and
        Plan.safe_version?(target)

  defp safe_target?(_target), do: false

  defp running_version(opts), do: Keyword.get(opts, :current_version) || Version.current()

  defp release_root(opts) do
    Keyword.get(opts, :release_root) || System.get_env("RELEASE_ROOT") ||
      List.to_string(:code.root_dir())
  end

  defp paths_opts(opts), do: Keyword.get(opts, :paths_opts, [])
  defp os_pid, do: List.to_string(:os.getpid())

  defp sha256_file(path) do
    path
    |> File.stream!(2 * 1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
