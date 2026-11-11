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
    root = release_root(opts) |> Path.expand() |> resolve_root()
    versions = versions_dir(opts) |> Path.expand() |> resolve_root()

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

  # ──────────────────────────────────────────────────────────────────────────
  # Lemon Bot backend pointer
  #
  # The backend has its own installer-owned layout beside the runtime:
  # `~/.lemon/lemon_bot/versions/<version>-<channel>-<platform>/bot/` with
  # `~/.lemon/lemon_bot/current` pointing at `versions/<key>`. Callers name a
  # *key*, never a path, exactly as the runtime side names a version.
  # ──────────────────────────────────────────────────────────────────────────

  @spec bot_root(keyword()) :: String.t()
  def bot_root(opts), do: Path.join(Paths.home_state_dir(paths_opts(opts)), "lemon_bot")

  @spec bot_versions_dir(keyword()) :: String.t()
  def bot_versions_dir(opts), do: Path.join(bot_root(opts), "versions")

  @spec bot_current_link(keyword()) :: String.t()
  def bot_current_link(opts), do: Path.join(bot_root(opts), "current")

  @spec safe_bot_key?(term()) :: boolean()
  def safe_bot_key?(key) when is_binary(key),
    do:
      Path.type(key) == :relative and Path.basename(key) == key and
        Regex.match?(~r/\A[0-9A-Za-z][0-9A-Za-z._-]{0,127}\z/, key)

  def safe_bot_key?(_key), do: false

  @doc """
  True when `lemon_bot/current` is a symlink into the managed
  `lemon_bot/versions/` tree. An absent, foreign, or non-symlink pointer is
  not managed and `lemon update` leaves it alone.
  """
  @spec managed_bot?(keyword()) :: boolean()
  def managed_bot?(opts \\ []), do: match?({:ok, _key}, active_bot_key(opts))

  @spec active_bot(keyword()) :: String.t() | nil
  def active_bot(opts \\ []) do
    case active_bot_key(opts) do
      {:ok, key} -> key
      _ -> nil
    end
  end

  @spec active_bot_key(keyword()) :: {:ok, String.t()} | {:error, term()}
  def active_bot_key(opts \\ []) do
    versions = bot_versions_dir(opts) |> Path.expand()

    case File.read_link(bot_current_link(opts)) do
      {:ok, target} ->
        key = Path.basename(target)
        resolved = Path.expand(target, bot_root(opts))

        if safe_bot_key?(key) and resolved == Path.join(versions, key) do
          {:ok, key}
        else
          {:error, :unmanaged_bot_pointer}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec promote_bot(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def promote_bot(partial, key, opts) do
    if safe_bot_key?(key) do
      final = Path.join(bot_versions_dir(opts), key)

      cond do
        usable_bot?(final) -> {:ok, final}
        File.exists?(final) -> replace(partial, final)
        true -> rename_into_place(partial, final)
      end
    else
      {:error, :invalid_bot_target}
    end
  end

  @spec flip_bot(String.t(), keyword()) :: :ok | {:error, term()}
  def flip_bot(key, opts) do
    if safe_bot_key?(key) do
      root = bot_root(opts)
      current = bot_current_link(opts)
      tmp = Path.join(root, ".current.tmp.#{os_pid()}")

      try do
        File.rm(tmp)

        with :ok <- File.ln_s(Path.join("versions", key), tmp),
             :ok <- File.rename(tmp, current) do
          :ok
        else
          {:error, reason} -> {:error, {:bot_symlink_failed, reason}}
        end
      after
        File.rm(tmp)
      end
    else
      {:error, :invalid_bot_target}
    end
  end

  @spec restore_bot_after_failed_flip(String.t() | nil, String.t(), keyword()) ::
          :ok | {:error, term()}
  def restore_bot_after_failed_flip(nil, _attempted, _opts), do: :ok

  def restore_bot_after_failed_flip(previous, attempted, opts) do
    if active_bot(opts) == attempted, do: flip_bot(previous, opts), else: :ok
  end

  @spec verify_active_bot(String.t(), keyword()) :: :ok | {:error, term()}
  def verify_active_bot(key, opts) do
    if active_bot(opts) == key do
      binary = Path.join([bot_versions_dir(opts), key, "bot/bin/lemon-bot"])

      case File.lstat(binary) do
        {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 ->
          run_active_bot_verifier(key, opts)

        _ ->
          {:error, :invalid_bot_binary}
      end
    else
      {:error, :active_bot_verification_failed}
    end
  end

  # The same post-flip proof seam the runtime side has: production callers do
  # not provide it, transaction tests use it to prove both pointers are
  # restored together.
  defp run_active_bot_verifier(key, opts) do
    case Keyword.get(opts, :active_bot_verify_fun) do
      fun when is_function(fun, 1) -> fun.(key)
      _ -> :ok
    end
  end

  @spec verify_bot_staged(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def verify_bot_staged(dir, version, platform, opts) do
    binary = Path.join(dir, "bot/bin/lemon-bot")
    web_dir = Path.join(dir, "bot/web")

    with :ok <- validate_bot_binary(binary),
         :ok <- validate_bot_web(web_dir),
         :ok <- validate_bot_native_addons(dir, platform, opts),
         :ok <- verify_bot_version(binary, version, opts) do
      :ok
    end
  end

  defp validate_bot_binary(binary) do
    case File.lstat(binary) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :bot_binary_is_symlink}

      _ ->
        {:error, {:incomplete_bot_release, "bot/bin/lemon-bot"}}
    end
  end

  defp validate_bot_web(web_dir) do
    if File.dir?(web_dir) and web_dir |> Path.join("**/*") |> Path.wildcard() |> Enum.any?() do
      :ok
    else
      {:error, {:incomplete_bot_release, "bot/web"}}
    end
  end

  # Mirrors the installer's `verify_bot` presence checks. An unrecognised
  # platform tag has no known host-native package name, so there is nothing to
  # assert; the version check below still has to pass.
  defp validate_bot_native_addons(dir, platform, _opts) do
    case native_platform(platform) do
      nil ->
        :ok

      native ->
        native_root = Path.join(dir, "bot/node_modules/@img/sharp-#{native}")
        libvips_root = Path.join(dir, "bot/node_modules/@img/sharp-libvips-#{native}")

        cond do
          not File.regular?(Path.join(native_root, "package.json")) ->
            {:error, {:incomplete_bot_release, "bot/node_modules/@img/sharp-#{native}"}}

          not File.regular?(Path.join(libvips_root, "package.json")) ->
            {:error, {:incomplete_bot_release, "bot/node_modules/@img/sharp-libvips-#{native}"}}

          not File.regular?(Path.join(native_root, "lib/sharp-#{native}.node")) ->
            {:error, {:incomplete_bot_release, "bot/node_modules/@img/sharp-#{native}/lib"}}

          true ->
            :ok
        end
    end
  end

  defp native_platform("linux-x86_64"), do: "linux-x64"
  defp native_platform("linux-arm64"), do: "linux-arm64"
  defp native_platform("darwin-arm64"), do: "darwin-arm64"
  defp native_platform("darwin-x86_64"), do: "darwin-x64"
  defp native_platform(_platform), do: nil

  defp verify_bot_version(binary, version, opts) do
    case Keyword.get(opts, :bot_version_verify_fun) do
      fun when is_function(fun, 2) ->
        fun.(binary, version)

      _ ->
        task =
          Task.async(fn ->
            try do
              System.cmd(binary, ["--version"],
                env: Keyword.get_lazy(opts, :release_command_env, &command_env/0),
                stderr_to_stdout: true
              )
            rescue
              _ -> {"", 1}
            end
          end)

        case Task.yield(task, Keyword.get(opts, :bot_version_timeout_ms, 15_000)) ||
               Task.shutdown(task, :brutal_kill) do
          {:ok, {output, 0}} ->
            expected = "lemon-bot #{version}"

            if String.trim(output) == expected do
              :ok
            else
              {:error, :staged_bot_version_mismatch}
            end

          {:ok, {_output, _status}} ->
            {:error, :staged_bot_version_command_failed}

          {:exit, _reason} ->
            {:error, :staged_bot_version_command_failed}

          nil ->
            {:error, :staged_bot_version_timeout}
        end
    end
  end

  defp usable_bot?(dir) do
    binary = Path.join(dir, "bot/bin/lemon-bot")

    case File.lstat(binary) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> true
      _ -> false
    end
  end

  @spec prune_bot([String.t()], keyword()) :: :ok
  def prune_bot(protected_keys, opts) do
    dir = bot_versions_dir(opts)

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in protected_keys or &1 == "current"))
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.reject(&(String.ends_with?(&1, ".partial") or String.contains?(&1, ".broken.")))
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.sort(:desc)
        |> Enum.drop(@keep_versions)
        |> Enum.each(&File.rm_rf(Path.join(dir, &1)))

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Environment overrides for invoking another release from an eval VM.

  Generated release selection must not pin a child to the eval VM's old root.
  External operator sysconfig/vmargs/tmp overrides remain in effect; only paths
  inside the inherited release are removed. Control-plane port, node identity,
  cookie and ordinary Lemon configuration are inherited unchanged.
  """
  @spec command_env() :: [{String.t(), nil}]
  def command_env do
    generated =
      ~w(RELEASE_ROOT RELEASE_VSN RELEASE_NAME RELEASE_PROG RELEASE_COMMAND RELEASE_MODE RELEASE_BOOT_SCRIPT RELEASE_BOOT_SCRIPT_CLEAN)

    root = System.get_env("RELEASE_ROOT")

    release_paths =
      Enum.filter(
        ~w(RELEASE_SYS_CONFIG RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_TMP),
        fn name ->
          case {root, System.get_env(name)} do
            {root, value} when is_binary(root) and is_binary(value) ->
              expanded = Path.expand(value)
              resolved = resolve_root(expanded)
              inherited = Path.expand(root)
              physical = resolve_root(inherited)

              expanded == inherited or String.starts_with?(expanded, inherited <> "/") or
                resolved == physical or String.starts_with?(resolved, physical <> "/")

            _ ->
              false
          end
        end
      )

    Enum.map(generated ++ release_paths, &{&1, nil})
  end

  defp run_version_command(path, version, opts) do
    task =
      Task.async(fn ->
        try do
          System.cmd(path, ["version"],
            env: Keyword.get_lazy(opts, :release_command_env, &command_env/0),
            stderr_to_stdout: true
          )
        rescue
          _ -> {"", 1}
        end
      end)

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

  defp resolve_root(path, remaining \\ 40)
  defp resolve_root(path, 0), do: path

  defp resolve_root(path, remaining) do
    parent = Path.dirname(path)

    if parent == path do
      path
    else
      resolved = Path.join(resolve_root(parent, remaining), Path.basename(path))

      case File.read_link(resolved) do
        {:ok, target} -> resolve_root(Path.expand(target, Path.dirname(resolved)), remaining - 1)
        {:error, _reason} -> resolved
      end
    end
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
