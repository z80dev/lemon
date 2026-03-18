defmodule LemonCore.Secrets.MasterKey do
  @moduledoc """
  Master key resolution and initialization for encrypted secrets.

  Resolution order:
  1. macOS Keychain entry (preferred)
  2. `LEMON_SECRETS_MASTER_KEY` environment variable
  3. `~/.lemon/secrets_master_key` file
  """

  alias LemonCore.Secrets.Keychain

  @env_var "LEMON_SECRETS_MASTER_KEY"
  @master_key_bytes 32

  @spec resolve(keyword()) ::
          {:ok, binary(), :keychain | :env | :file} | {:error, atom() | tuple()}
  def resolve(opts \\ []) do
    keychain_module = Keyword.get(opts, :keychain_module, Keychain)

    case resolve_from_keychain(keychain_module, opts) do
      {:ok, _key, :keychain} = ok ->
        ok

      {:error, :missing} ->
        resolve_from_env_or_file(opts)

      {:error, :keychain_unavailable} ->
        resolve_from_env_or_file(opts)

      {:error, :invalid_master_key} ->
        case resolve_from_env_or_file(opts) do
          {:ok, _key, source} = ok when source in [:env, :file] -> ok
          {:error, _} -> {:error, :invalid_master_key}
        end

      {:error, reason} ->
        case resolve_from_env_or_file(opts) do
          {:ok, _key, source} = ok when source in [:env, :file] -> ok
          {:error, :invalid_master_key} -> {:error, :invalid_master_key}
          {:error, :missing_master_key} -> {:error, {:keychain_failed, reason}}
        end
    end
  end

  @spec init(keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def init(opts \\ []) do
    keychain_module = Keyword.get(opts, :keychain_module, Keychain)
    encoded = generate_encoded_key()

    case keychain_module.put_master_key(encoded, opts) do
      :ok ->
        {:ok, %{source: :keychain, configured: true}}

      {:error, :unavailable} ->
        {:error, :keychain_unavailable}

      {:error, reason} ->
        {:error, {:keychain_failed, reason}}
    end
  end

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    keychain_module = Keyword.get(opts, :keychain_module, Keychain)

    keychain_available =
      if Code.ensure_loaded?(keychain_module) and
           function_exported?(keychain_module, :available?, 0) do
        keychain_module.available?()
      else
        false
      end

    env_present? =
      case env_getter(opts).(@env_var) do
        value when is_binary(value) and value != "" -> true
        _ -> false
      end

    file_present? =
      case default_file_path(opts) do
        nil ->
          false

        path ->
          case file_reader(opts).(path) do
            {:ok, value} when is_binary(value) -> String.trim(value) != ""
            _ -> false
          end
      end

    keychain_result = resolve_from_keychain(keychain_module, opts)

    env_result =
      case keychain_result do
        {:ok, _key, :keychain} -> nil
        _ -> resolve_from_env_or_file(opts)
      end

    source =
      cond do
        match?({:ok, _key, :keychain}, keychain_result) -> :keychain
        match?({:ok, _key, :env}, env_result) -> :env
        match?({:ok, _key, :file}, env_result) -> :file
        true -> nil
      end

    keychain_error =
      case keychain_result do
        {:error, reason} when reason in [:missing, :keychain_unavailable] -> nil
        {:error, reason} -> reason
        _ -> nil
      end

    %{
      configured: not is_nil(source),
      source: source,
      keychain_available: keychain_available,
      env_fallback: env_present?,
      file_fallback: file_present?,
      keychain_error: keychain_error
    }
  end

  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @spec generate_encoded_key() :: String.t()
  def generate_encoded_key do
    :crypto.strong_rand_bytes(@master_key_bytes)
    |> Base.encode64()
  end

  defp resolve_from_keychain(keychain_module, opts) do
    if Code.ensure_loaded?(keychain_module) and
         function_exported?(keychain_module, :get_master_key, 1) do
      case keychain_module.get_master_key(opts) do
        {:ok, encoded} ->
          with {:ok, decoded} <- decode_master_key(encoded) do
            {:ok, decoded, :keychain}
          end

        {:error, _} = error ->
          error
      end
    else
      {:error, :keychain_unavailable}
    end
  end

  defp resolve_from_env(opts) do
    case env_getter(opts).(@env_var) do
      value when is_binary(value) and value != "" ->
        with {:ok, decoded} <- decode_master_key(value) do
          {:ok, decoded, :env}
        end

      _ ->
        {:error, :missing_master_key}
    end
  end

  defp resolve_from_env_or_file(opts) do
    case resolve_from_env(opts) do
      {:error, :missing_master_key} -> resolve_from_file(opts)
      other -> other
    end
  end

  defp resolve_from_file(opts) do
    case default_file_path(opts) do
      nil ->
        {:error, :missing_master_key}

      path ->
        case file_reader(opts).(path) do
          {:ok, value} when is_binary(value) and value != "" ->
            with {:ok, decoded} <- decode_master_key(value) do
              {:ok, decoded, :file}
            end

          {:ok, _value} ->
            {:error, :invalid_master_key}

          {:error, :enoent} ->
            {:error, :missing_master_key}

          {:error, _reason} ->
            {:error, :missing_master_key}
        end
    end
  end

  defp decode_master_key(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, :invalid_master_key}

      true ->
        case Base.decode64(trimmed) do
          {:ok, decoded} when byte_size(decoded) >= @master_key_bytes -> {:ok, decoded}
          _ when byte_size(trimmed) >= @master_key_bytes -> {:ok, trimmed}
          _ -> {:error, :invalid_master_key}
        end
    end
  end

  defp decode_master_key(_), do: {:error, :invalid_master_key}

  defp env_getter(opts), do: Keyword.get(opts, :env_getter, &System.get_env/1)
  defp file_reader(opts), do: Keyword.get(opts, :file_reader, &File.read/1)

  defp default_file_path(opts) do
    case Keyword.get(opts, :home_dir) || env_getter(opts).("HOME") do
      value when is_binary(value) and value != "" ->
        Path.join([value, ".lemon", "secrets_master_key"])

      _ ->
        nil
    end
  end
end
