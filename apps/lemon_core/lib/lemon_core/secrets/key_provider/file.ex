defmodule LemonCore.Secrets.KeyProvider.File do
  @moduledoc """
  Master key provider backed by a file on disk.

  Defaults to `~/.lemon/secrets_master_key`; configure another location with
  `config :lemon_core, LemonCore.Secrets, key_file: "/etc/lemon/master_key"`
  or the `:key_file` option.

  This is the provisioning target on platforms without a system keychain: the
  key file is created with `0600` permissions inside a `0700` directory, and the
  mode is applied before any key material is written.

  A key file that is *already* readable beyond its owner — provisioned by hand,
  or restored from a backup that lost its mode — is warned about once per path
  and then used. Refusing it would lock you out of your own secrets over
  something `chmod 600` fixes, and `put/2` will not overwrite an existing key.
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

          {:error, _reason} ->
            {:error, :missing}
        end
    end
  end

  @impl true
  def put(value, opts) when is_binary(value) do
    case KeyProvider.key_file(opts) do
      nil ->
        {:error, :unavailable}

      path ->
        if occupied?(path, opts) do
          {:error, {:key_file_exists, path}}
        else
          write(path, value)
        end
    end
  end

  def put(_value, _opts), do: {:error, :invalid_value}

  @doc "Absolute path this provider reads and writes, or `nil` if undeterminable."
  @spec path(keyword()) :: Path.t() | nil
  def path(opts \\ []), do: KeyProvider.key_file(opts)

  defp reader(opts), do: Keyword.get(opts, :file_reader, &Elixir.File.read/1)

  # Refuse to overwrite key material: everything encrypted with the old key
  # would become unreadable.
  defp occupied?(path, opts) do
    if Keyword.get(opts, :force, false) do
      false
    else
      case reader(opts).(path) do
        {:ok, value} when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end
  end

  # Create-then-restrict-then-fill: `File.write/2` alone would put key material
  # on disk at whatever the umask allows and only narrow it afterwards, leaving
  # a window where the key is world-readable.
  defp write(path, value) do
    dir = Path.dirname(path)

    with :ok <- Elixir.File.mkdir_p(dir),
         _ <- Elixir.File.chmod(dir, @dir_mode),
         :ok <- Elixir.File.touch(path),
         :ok <- Elixir.File.chmod(path, @file_mode),
         :ok <- Elixir.File.write(path, String.trim(value) <> "\n") do
      :ok
    else
      {:error, reason} -> {:error, {:key_file_write_failed, reason}}
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

      if :persistent_term.get(key, false) do
        :ok
      else
        :persistent_term.put(key, true)

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
