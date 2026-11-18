defmodule LemonCore.Secrets.KeyProvider.File do
  @moduledoc """
  Master key provider backed by a file on disk.

  Defaults to `~/.lemon/secrets_master_key`; configure another location with
  `config :lemon_core, LemonCore.Secrets, key_file: "/etc/lemon/master_key"`
  or the `:key_file` option.

  This is the provisioning target on platforms without a system keychain: the
  key file is created with `0600` permissions inside a `0700` directory, and the
  mode is applied before any key material is written. Every write goes to a
  private temporary file in the same directory that is synced and then renamed
  over the key file, so a crash leaves either the old key or the new one —
  never a truncated file.

  A key file that is *already* readable beyond its owner — provisioned by hand,
  or restored from a backup that lost its mode — is warned about once per path
  and then used. Refusing it would lock you out of your own secrets over
  something `chmod 600` fixes, and `put/2` will not overwrite an existing key
  unless passed `force: true` (`mix lemon.secrets.init --force`, key rotation).
  Pass `check_permissions: false` to silence the check.
  """

  use LemonCore.Secrets.KeyProvider

  require Logger

  alias LemonCore.Secrets.KeyProvider

  @file_mode 0o600
  @dir_mode 0o700

  @impl true
  def name, do: :file

  @impl true
  def available?(opts), do: not is_nil(KeyProvider.key_file(opts))

  @impl true
  def fetch(opts) do
    case KeyProvider.key_file(opts) do
      nil ->
        {:error, :missing}

      path ->
        case reader(opts).(path) do
          {:ok, value} when is_binary(value) ->
            warn_loose_permissions_once(path, opts)
            if String.trim(value) == "", do: {:error, :invalid_master_key}, else: {:ok, value}

          {:error, :enoent} ->
            {:error, :missing}

          # Present but unreadable is a key we cannot see, not an absent one:
          # reporting `:missing` would let `init` provision a replacement.
          {:error, reason} ->
            {:error, {:key_file_unreadable, reason}}
        end
    end
  end

  @impl true
  def put(value, opts) when is_binary(value) do
    case KeyProvider.key_file(opts) do
      nil ->
        {:error, :unavailable}

      path ->
        force? = Keyword.get(opts, :force, false)

        case occupancy(path, force?) do
          :free -> write(path, value, force?, opts)
          :occupied -> {:error, {:key_file_exists, path}}
          {:error, reason} -> {:error, {:key_file_check_failed, reason}}
        end
    end
  end

  def put(_value, _opts), do: {:error, :invalid_value}

  @doc "Absolute path this provider reads and writes, or `nil` if undeterminable."
  @spec path(keyword()) :: Path.t() | nil
  def path(opts \\ []), do: KeyProvider.key_file(opts)

  @doc """
  Whether a replaced key file can be made durable on this host: runs the
  directory flush on the key file's directory and returns its result.
  `LemonCore.Secrets.KeyRotation` refuses to rotate a file key without it.
  The flush is `LemonCore.Durable.sync_directory/1` unless the
  `:directory_sync` option supplies another function.
  """
  @spec durable_replace(keyword()) :: :ok | {:error, term()}
  def durable_replace(opts) do
    case KeyProvider.key_file(opts) do
      nil -> {:error, :unavailable}
      path -> directory_sync(opts).(Path.dirname(path))
    end
  end

  defp reader(opts), do: Keyword.get(opts, :file_reader, &Elixir.File.read/1)

  defp directory_sync(opts),
    do: KeyProvider.option(opts, :directory_sync, &LemonCore.Durable.sync_directory/1)

  # Refuse to overwrite key material: everything encrypted with the old key
  # would become unreadable. Existence is what counts, not readability: an
  # unreadable, empty or dangling-symlink key file is still occupied, and a
  # failed check is an error rather than "free".
  defp occupancy(_path, true), do: :free

  defp occupancy(path, false) do
    case Elixir.File.lstat(path) do
      {:ok, _stat} -> :occupied
      {:error, :enoent} -> :free
      {:error, reason} -> {:error, reason}
    end
  end

  # Create-then-restrict-then-fill, then publish: `File.write/2` alone would
  # put key material on disk at whatever the umask allows, and rewriting the
  # key file in place would leave a truncated key if interrupted. The
  # temporary file is exclusive, `0600` before it holds key material, and
  # synced before it becomes the key; the directory is then synced so the
  # publication survives a host crash. A new key is published with a hard
  # link, which fails with `:eexist` instead of replacing a key file that
  # appeared after the check; only `force: true` (rotation, `init --force`)
  # replaces by atomic rename. Where no synchronous directory flush exists
  # (macOS) durability is not proven; key rotation checks
  # `durable_replace/1` and refuses there. A failed flush on a host that
  # supports it is reported even though the key was already published.
  defp write(path, value, force?, opts) do
    dir = Path.dirname(path)
    suffix = "#{System.pid()}.#{System.unique_integer([:positive])}"
    temporary = Path.join(dir, ".#{Path.basename(path)}.#{suffix}")

    with :ok <- Elixir.File.mkdir_p(dir),
         _ <- Elixir.File.chmod(dir, @dir_mode),
         :ok <- write_private(temporary, String.trim(value) <> "\n"),
         :ok <- publish(temporary, path, force?),
         :ok <- sync_written_directory(dir, opts) do
      :ok
    else
      {:error, :eexist} ->
        _ = Elixir.File.rm(temporary)
        {:error, {:key_file_exists, path}}

      {:error, reason} ->
        _ = Elixir.File.rm(temporary)
        {:error, {:key_file_write_failed, reason}}
    end
  end

  defp publish(temporary, path, true), do: Elixir.File.rename(temporary, path)

  defp publish(temporary, path, false) do
    with :ok <- Elixir.File.ln(temporary, path) do
      _ = Elixir.File.rm(temporary)
      :ok
    end
  end

  defp sync_written_directory(dir, opts) do
    case directory_sync(opts).(dir) do
      {:error, :directory_sync_unsupported} -> :ok
      result -> result
    end
  end

  defp write_private(path, contents) do
    with {:ok, device} <- :file.open(path, [:write, :exclusive, :binary, :raw]) do
      result =
        with :ok <- Elixir.File.chmod(path, @file_mode),
             :ok <- :file.write(device, contents) do
          :file.sync(device)
        end

      :ok = :file.close(device)
      result
    end
  end

  # Reported, not enforced: refusing to start because of a file mode would lock
  # people out of their own secrets over something they can fix in one command,
  # and the mode may be an artifact of how the file was provisioned. Once per
  # path, so it does not repeat on every resolve.
  defp warn_loose_permissions_once(path, opts) do
    with true <- Keyword.get(opts, :check_permissions, true),
         {:ok, %Elixir.File.Stat{mode: mode}} <- Elixir.File.stat(path),
         group_or_world when group_or_world != 0 <- Bitwise.band(mode, 0o077) do
      key = {__MODULE__, :warned_permissions, path}

      if LemonCore.RuntimeCache.warn_once?(key) do
        Logger.warning(
          "Secrets master key file #{path} is readable beyond its owner " <>
            "(mode #{Integer.to_string(Bitwise.band(mode, 0o777), 8)}). It is being used " <>
            "anyway. Restrict it with `chmod 600 #{path}`."
        )
      end
    end

    :ok
  rescue
    _ -> :ok
  end
end
