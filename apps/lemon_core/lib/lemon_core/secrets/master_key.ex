defmodule LemonCore.Secrets.MasterKey do
  @moduledoc """
  Master key resolution and initialization for encrypted secrets.

  Resolution order (platform-dependent):

      macOS:   Keychain → KeyFile → LEMON_SECRETS_MASTER_KEY env
      Linux:   SecretService → KeyFile → LEMON_SECRETS_MASTER_KEY env
      Other:   KeyFile → LEMON_SECRETS_MASTER_KEY env
  """

  alias LemonCore.Secrets.{KeyFile, Keychain, SecretService}

  @env_var "LEMON_SECRETS_MASTER_KEY"
  @master_key_bytes 32

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @spec resolve(keyword()) :: {:ok, binary(), atom()} | {:error, atom() | tuple()}
  def resolve(opts \\ []) do
    if Keyword.has_key?(opts, :keychain_module) do
      resolve_legacy(opts)
    else
      resolve_multi_backend(opts)
    end
  end

  @spec init(keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def init(opts \\ []) do
    if Keyword.has_key?(opts, :keychain_module) do
      init_legacy(opts)
    else
      init_multi_backend(opts)
    end
  end

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    if Keyword.has_key?(opts, :keychain_module) do
      status_legacy(opts)
    else
      status_multi_backend(opts)
    end
  end

  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @spec generate_encoded_key() :: String.t()
  def generate_encoded_key do
    :crypto.strong_rand_bytes(@master_key_bytes)
    |> Base.encode64()
  end

  @spec default_backends() :: [module()]
  def default_backends do
    case :os.type() do
      {:unix, :darwin} -> [Keychain, KeyFile]
      {:unix, _} -> [SecretService, KeyFile]
      _ -> [KeyFile]
    end
  end

  @spec backend_source(module()) :: atom()
  def backend_source(module) do
    case module do
      Keychain -> :keychain
      SecretService -> :secret_service
      KeyFile -> :key_file
      other -> other |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
    end
  end

  # -------------------------------------------------------------------
  # Multi-backend resolution (new path — no :keychain_module in opts)
  # -------------------------------------------------------------------

  defp resolve_multi_backend(opts) do
    backends = Keyword.get(opts, :backends, default_backends())

    case try_backends_resolve(backends, opts) do
      {:ok, _key, _source} = ok -> ok
      :no_match -> resolve_from_env(opts)
    end
  end

  defp try_backends_resolve([], _opts), do: :no_match

  defp try_backends_resolve([backend | rest], opts) do
    if backend_available?(backend) do
      case backend.get_master_key(opts) do
        {:ok, encoded} ->
          case decode_master_key(encoded) do
            {:ok, decoded} -> {:ok, decoded, backend_source(backend)}
            {:error, _} -> try_backends_resolve(rest, opts)
          end

        {:error, :missing} ->
          try_backends_resolve(rest, opts)

        {:error, _} ->
          try_backends_resolve(rest, opts)
      end
    else
      try_backends_resolve(rest, opts)
    end
  end

  defp init_multi_backend(opts) do
    backends = Keyword.get(opts, :backends, default_backends())
    encoded = generate_encoded_key()

    case try_backends_init(backends, encoded, opts) do
      {:ok, _} = ok -> ok
      :no_backend -> {:error, :no_backend_available}
    end
  end

  defp try_backends_init([], _encoded, _opts), do: :no_backend

  defp try_backends_init([backend | rest], encoded, opts) do
    if backend_available?(backend) do
      case backend.put_master_key(encoded, opts) do
        :ok -> {:ok, %{source: backend_source(backend), configured: true}}
        {:error, _} -> try_backends_init(rest, encoded, opts)
      end
    else
      try_backends_init(rest, encoded, opts)
    end
  end

  defp status_multi_backend(opts) do
    backends = Keyword.get(opts, :backends, default_backends())

    env_present? =
      case env_getter(opts).(@env_var) do
        value when is_binary(value) and value != "" -> true
        _ -> false
      end

    backend_statuses =
      Enum.map(backends, fn backend ->
        available = backend_available?(backend)
        source = backend_source(backend)

        result =
          if available do
            case backend.get_master_key(opts) do
              {:ok, encoded} ->
                case decode_master_key(encoded) do
                  {:ok, _} -> :ok
                  {:error, reason} -> {:error, reason}
                end

              {:error, reason} ->
                {:error, reason}
            end
          else
            {:error, :unavailable}
          end

        %{backend: source, module: backend, available: available, result: result}
      end)

    active =
      Enum.find(backend_statuses, fn s -> s.available and s.result == :ok end)

    source =
      cond do
        active != nil -> active.backend
        env_present? -> :env
        true -> nil
      end

    # Preserve backward-compat keys
    keychain_status = Enum.find(backend_statuses, &(&1.module == Keychain))

    keychain_available =
      if keychain_status, do: keychain_status.available, else: false

    keychain_error =
      case keychain_status do
        %{result: {:error, reason}} when reason not in [:missing, :unavailable] -> reason
        _ -> nil
      end

    %{
      configured: not is_nil(source),
      source: source,
      keychain_available: keychain_available,
      env_fallback: env_present?,
      keychain_error: keychain_error,
      backends: backend_statuses
    }
  end

  defp backend_available?(backend) do
    Code.ensure_loaded?(backend) and
      function_exported?(backend, :available?, 0) and
      backend.available?()
  end

  # -------------------------------------------------------------------
  # Legacy single-backend path (opts contain :keychain_module)
  # -------------------------------------------------------------------

  defp resolve_legacy(opts) do
    keychain_module = Keyword.fetch!(opts, :keychain_module)

    case resolve_from_keychain(keychain_module, opts) do
      {:ok, _key, :keychain} = ok ->
        ok

      {:error, :missing} ->
        resolve_from_env(opts)

      {:error, :keychain_unavailable} ->
        resolve_from_env(opts)

      {:error, :invalid_master_key} ->
        case resolve_from_env(opts) do
          {:ok, _key, :env} = ok -> ok
          {:error, _} -> {:error, :invalid_master_key}
        end

      {:error, reason} ->
        case resolve_from_env(opts) do
          {:ok, _key, :env} = ok -> ok
          {:error, :invalid_master_key} -> {:error, :invalid_master_key}
          {:error, :missing_master_key} -> {:error, {:keychain_failed, reason}}
        end
    end
  end

  defp init_legacy(opts) do
    keychain_module = Keyword.fetch!(opts, :keychain_module)
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

  defp status_legacy(opts) do
    keychain_module = Keyword.fetch!(opts, :keychain_module)

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

    keychain_result = resolve_from_keychain(keychain_module, opts)

    env_result =
      case keychain_result do
        {:ok, _key, :keychain} -> nil
        _ -> resolve_from_env(opts)
      end

    source =
      cond do
        match?({:ok, _key, :keychain}, keychain_result) -> :keychain
        match?({:ok, _key, :env}, env_result) -> :env
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
      keychain_error: keychain_error
    }
  end

  # -------------------------------------------------------------------
  # Shared helpers
  # -------------------------------------------------------------------

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
end
