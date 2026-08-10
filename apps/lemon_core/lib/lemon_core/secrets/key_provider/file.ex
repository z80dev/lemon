defmodule LemonCore.Secrets.KeyProvider.File do
  @moduledoc """
  Master key provider backed by a file on disk.

  Defaults to `~/.lemon/secrets_master_key`; configure another location with
  `config :lemon_core, LemonCore.Secrets, key_file: "/etc/lemon/master_key"`
  or the `:key_file` option.

  This is the provisioning target on platforms without a system keychain: the
  key file is created with `0600` permissions inside a `0700` directory.
  """

  use LemonCore.Secrets.KeyProvider

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

  defp write(path, value) do
    dir = Path.dirname(path)

    with :ok <- Elixir.File.mkdir_p(dir),
         _ <- Elixir.File.chmod(dir, @dir_mode),
         :ok <- Elixir.File.write(path, String.trim(value) <> "\n"),
         :ok <- Elixir.File.chmod(path, @file_mode) do
      :ok
    else
      {:error, reason} -> {:error, {:key_file_write_failed, reason}}
    end
  end
end
