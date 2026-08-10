defmodule LemonCore.Secrets.MasterKey do
  @moduledoc """
  Master key resolution and initialization for encrypted secrets.

  The key is looked up through a chain of `LemonCore.Secrets.KeyProvider`
  modules. The default chain preserves the historical order:

  1. macOS Keychain entry (macOS only)
  2. `LEMON_SECRETS_MASTER_KEY` environment variable
  3. `~/.lemon/secrets_master_key` file

  Both the chain and the locations it looks at are configurable:

      config :lemon_core, LemonCore.Secrets,
        key_providers: [:env, :file],
        key_file: "/etc/lemon/master_key",
        env_var: "LEMON_SECRETS_MASTER_KEY"

  ## Key material

  A master key is 32 random bytes, stored base64-encoded — exactly what
  `generate_encoded_key/0`, `mix lemon.secrets.init` or `openssl rand -base64 32`
  produce. Passphrase-like values are rejected with `:weak_master_key` because
  they are used as key material verbatim, without password stretching. Setups
  that already encrypted secrets under such a value can keep working by opting
  in explicitly:

      config :lemon_core, LemonCore.Secrets, allow_legacy_raw_keys: true

  which logs a deprecation warning on first use. Re-encrypting under a proper
  key is the real fix; see the "Key rotation" section of `LemonCore.Secrets`.
  """

  require Logger

  alias LemonCore.Secrets.KeyProvider

  @master_key_bytes 32

  # Reasons that mean "this provider has nothing for us" rather than a failure.
  @skip_reasons [:missing, :unavailable, :keychain_unavailable, :not_found]
  @invalid_reasons [:invalid_master_key, :weak_master_key]

  @type source :: atom()

  @spec resolve(keyword()) :: {:ok, binary(), source()} | {:error, atom() | tuple()}
  def resolve(opts \\ []) do
    opts
    |> KeyProvider.order()
    |> resolve_chain(opts, %{invalid: nil, failure: nil})
  end

  @doc """
  Generates a master key and stores it with the first writable provider.

  On macOS that is the Keychain; elsewhere the keychain provider reports itself
  unavailable and the key lands in the configured key file (`0600`). Pass
  `target: :file` (or any provider name) to force one, and `force: true` to
  replace an existing key file — note that doing so makes every secret already
  encrypted under the old key unreadable.
  """
  @spec init(keyword()) :: {:ok, map()} | {:error, atom() | tuple()}
  def init(opts \\ []) do
    encoded = generate_encoded_key()

    opts
    |> init_targets()
    |> init_chain(encoded, opts, [])
  end

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    providers = KeyProvider.order(opts)
    keychain = find_provider(providers, :keychain)

    keychain_result = keychain && fetch_key(keychain, opts)

    source =
      case resolve(opts) do
        {:ok, _key, source} -> source
        {:error, _reason} -> nil
      end

    %{
      configured: not is_nil(source),
      source: source,
      keychain_available: not is_nil(keychain) and KeyProvider.available?(keychain, opts),
      env_fallback: present?(find_provider(providers, :env), opts),
      file_fallback: present?(find_provider(providers, :file), opts),
      keychain_error: provider_error(keychain_result),
      providers: Enum.map(providers, &KeyProvider.name/1),
      key_file: KeyProvider.key_file(opts)
    }
  end

  @spec env_var(keyword()) :: String.t()
  def env_var(opts \\ []), do: KeyProvider.env_var(opts)

  @spec key_file(keyword()) :: Path.t() | nil
  def key_file(opts \\ []), do: KeyProvider.key_file(opts)

  @spec generate_encoded_key() :: String.t()
  def generate_encoded_key do
    @master_key_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode64()
  end

  defp resolve_chain([], _opts, acc) do
    cond do
      acc.invalid -> {:error, acc.invalid}
      acc.failure -> {:error, acc.failure}
      true -> {:error, :missing_master_key}
    end
  end

  defp resolve_chain([provider | rest], opts, acc) do
    case fetch_key(provider, opts) do
      {:ok, key} ->
        {:ok, key, KeyProvider.name(provider)}

      {:error, reason} when reason in @skip_reasons ->
        resolve_chain(rest, opts, acc)

      {:error, reason} when reason in @invalid_reasons ->
        case KeyProvider.on_invalid(provider) do
          :continue -> resolve_chain(rest, opts, %{acc | invalid: acc.invalid || reason})
          _halt -> {:error, reason}
        end

      {:error, reason} ->
        resolve_chain(rest, opts, %{acc | failure: acc.failure || wrap_error(provider, reason)})
    end
  end

  defp fetch_key(provider, opts) do
    if KeyProvider.available?(provider, opts) do
      case provider.fetch(opts) do
        {:ok, encoded} -> decode_master_key(encoded, opts)
        {:error, _reason} = error -> error
      end
    else
      {:error, :unavailable}
    end
  end

  defp init_targets(opts) do
    providers = opts |> KeyProvider.order() |> Enum.filter(&KeyProvider.supports_put?/1)

    case Keyword.get(opts, :target) do
      nil -> providers
      target -> Enum.filter(providers, &(KeyProvider.name(&1) == target or &1 == target))
    end
  end

  # Only "nothing here" reasons reach this point; real failures return early.
  defp init_chain([], _encoded, _opts, errors) do
    if Enum.any?(errors, fn {name, _reason} -> name == :keychain end) do
      {:error, :keychain_unavailable}
    else
      {:error, :no_key_provider}
    end
  end

  defp init_chain([provider | rest], encoded, opts, errors) do
    name = KeyProvider.name(provider)

    if KeyProvider.available?(provider, opts) do
      case provider.put(encoded, opts) do
        :ok ->
          {:ok, %{source: name, configured: true, key_file: init_location(name, opts)}}

        {:error, reason} when reason in @skip_reasons ->
          init_chain(rest, encoded, opts, errors ++ [{name, reason}])

        {:error, reason} ->
          # A backend that exists but refused is a real failure: falling through
          # would write a second, conflicting key somewhere else.
          {:error, init_error(provider, reason)}
      end
    else
      init_chain(rest, encoded, opts, errors ++ [{name, :unavailable}])
    end
  end

  defp init_location(:file, opts), do: KeyProvider.key_file(opts)
  defp init_location(_name, _opts), do: nil

  defp find_provider(providers, name),
    do: Enum.find(providers, &(KeyProvider.name(&1) == name))

  defp present?(nil, _opts), do: false

  defp present?(provider, opts) do
    KeyProvider.available?(provider, opts) and match?({:ok, _}, provider.fetch(opts))
  end

  defp provider_error({:error, reason}) when reason not in @skip_reasons, do: reason
  defp provider_error(_result), do: nil

  defp init_error(provider, reason) do
    case KeyProvider.name(provider) do
      :keychain -> {:keychain_failed, reason}
      _other -> reason
    end
  end

  defp wrap_error(provider, reason) do
    case KeyProvider.name(provider) do
      :keychain -> {:keychain_failed, reason}
      name -> {:key_provider_failed, name, reason}
    end
  end

  defp decode_master_key(value, opts) when is_binary(value) do
    trimmed = String.trim(value)

    case Base.decode64(trimmed) do
      {:ok, decoded} when byte_size(decoded) >= @master_key_bytes ->
        {:ok, decoded}

      _ when byte_size(trimmed) >= @master_key_bytes ->
        legacy_raw_key(trimmed, opts)

      _ ->
        {:error, :invalid_master_key}
    end
  end

  defp decode_master_key(_value, _opts), do: {:error, :invalid_master_key}

  defp legacy_raw_key(trimmed, opts) do
    if KeyProvider.option(opts, :allow_legacy_raw_keys, false) do
      warn_once(:legacy_raw_key, """
      Lemon secrets master key is a raw string, not base64-encoded 32-byte key \
      material. It is used verbatim as key material, with no password \
      stretching. Generate a real key with `mix lemon.secrets.init` (or \
      `openssl rand -base64 32`), re-import your secrets under it, and drop \
      `allow_legacy_raw_keys` from your config.\
      """)

      {:ok, trimmed}
    else
      warn_once(:weak_master_key, """
      Lemon secrets master key is not base64-encoded 32-byte key material and \
      was rejected. Generate one with `mix lemon.secrets.init` (or \
      `openssl rand -base64 32`). To keep using an existing raw-string key, \
      set `config :lemon_core, LemonCore.Secrets, allow_legacy_raw_keys: true`.\
      """)

      {:error, :weak_master_key}
    end
  end

  defp warn_once(key, message) do
    term_key = {__MODULE__, :warned, key}

    if :persistent_term.get(term_key, false) do
      :ok
    else
      :persistent_term.put(term_key, true)
      Logger.warning(message)
      :ok
    end
  end
end
