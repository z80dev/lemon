defmodule LemonCore.Secrets.KeyFile do
  @moduledoc """
  File-based master key storage fallback.

  Reads and writes the master key to `~/.lemon/master.key` (configurable
  via the `:key_file_path` option).  Always available on every platform.
  """

  require Logger

  @behaviour LemonCore.Secrets.KeyBackend

  @default_relative_path ".lemon/master.key"

  @spec available?() :: boolean()
  def available?, do: true

  @spec get_master_key(keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_master_key(opts \\ []) do
    path = key_file_path(opts)

    case File.read(path) do
      {:ok, content} ->
        warn_if_permissions_too_open(path)
        trimmed = String.trim(content)
        if trimmed == "", do: {:error, :missing}, else: {:ok, trimmed}

      {:error, :enoent} ->
        {:error, :missing}

      {:error, reason} ->
        {:error, {:file_error, reason}}
    end
  end

  @spec put_master_key(String.t(), keyword()) :: :ok | {:error, term()}
  def put_master_key(value, opts \\ [])

  def put_master_key(value, opts) when is_binary(value) do
    path = key_file_path(opts)

    with :ok <- ensure_parent_dir(path),
         :ok <- File.write(path, value),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  def put_master_key(_, _), do: {:error, :invalid_value}

  @spec delete_master_key(keyword()) :: :ok | {:error, term()}
  def delete_master_key(opts \\ []) do
    path = key_file_path(opts)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  @doc false
  def key_file_path(opts \\ []) do
    Keyword.get_lazy(opts, :key_file_path, fn ->
      Path.join(System.user_home!(), @default_relative_path)
    end)
  end

  defp ensure_parent_dir(path) do
    path |> Path.dirname() |> File.mkdir_p()
  end

  defp warn_if_permissions_too_open(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        # Check if group or other bits are set (anything beyond owner rw)
        if Bitwise.band(mode, 0o077) != 0 do
          Logger.warning(
            "Master key file #{path} has overly permissive mode #{inspect(mode, base: :octal)}. " <>
              "Run: chmod 600 #{path}"
          )
        end

      _ ->
        :ok
    end
  end
end
