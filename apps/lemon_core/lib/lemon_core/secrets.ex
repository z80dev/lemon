defmodule LemonCore.Secrets do
  @moduledoc """
  Encrypted secrets storage backed by `LemonCore.Store`.

  Secret values are encrypted at rest and never returned by list/status APIs.
  """

  alias LemonCore.Clock
  alias LemonCore.Store
  alias LemonCore.Secrets.{Crypto, MasterKey}

  @table :secrets_v1
  @default_owner "default"
  @default_provider "manual"

  @type owner :: String.t()
  @type name :: String.t()

  @type secret_metadata :: %{
          required(:owner) => owner(),
          required(:name) => name(),
          required(:provider) => String.t(),
          required(:expires_at) => integer() | nil,
          required(:usage_count) => non_neg_integer(),
          required(:last_used_at) => integer() | nil,
          required(:created_at) => integer(),
          required(:updated_at) => integer(),
          required(:version) => String.t()
        }

  @spec table() :: atom()
  def table, do: @table

  @spec default_owner() :: owner()
  def default_owner, do: @default_owner

  @spec set(name(), String.t(), keyword()) :: {:ok, secret_metadata()} | {:error, atom()}
  def set(name, value, opts \\ [])

  def set(name, value, opts) when is_binary(value) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, master_key, _source} <- MasterKey.resolve(opts),
         {:ok, encrypted} <- Crypto.encrypt(value, master_key) do
      now = Clock.now_ms()
      existing = Store.get(@table, {owner, name}) || %{}

      record = %{
        ciphertext: encrypted.ciphertext,
        nonce: encrypted.nonce,
        salt: encrypted.salt,
        provider: normalize_optional_string(Keyword.get(opts, :provider)) || @default_provider,
        expires_at: normalize_optional_integer(Keyword.get(opts, :expires_at)),
        usage_count: 0,
        last_used_at: nil,
        created_at: get_field(existing, :created_at) || now,
        updated_at: now,
        version: encrypted.version
      }

      :ok = Store.put(@table, {owner, name}, record)
      emit_secret_event(owner, name, :set)
      {:ok, metadata(owner, name, record)}
    else
      {:error, :missing_master_key} -> {:error, :missing_master_key}
      {:error, :invalid_master_key} -> {:error, :invalid_master_key}
      {:error, :invalid_secret_name} -> {:error, :invalid_secret_name}
      {:error, :invalid_owner} -> {:error, :invalid_owner}
      {:error, reason} -> {:error, reason}
    end
  end

  def set(_, _, _), do: {:error, :invalid_secret_value}

  @spec get(name(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def get(name, opts \\ []) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, entry} <- fetch_active_entry(owner, name),
         {:ok, master_key, _source} <- MasterKey.resolve(opts),
         {:ok, plaintext} <- Crypto.decrypt(entry, master_key) do
      touch_entry(owner, name, entry)
      {:ok, plaintext}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, :expired} -> {:error, :expired}
      {:error, :missing_master_key} -> {:error, :missing_master_key}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolve(name(), keyword()) :: {:ok, String.t(), :store | :env} | {:error, atom()}
  def resolve(name, opts \\ []) do
    prefer_env = Keyword.get(opts, :prefer_env, false)
    env_fallback = Keyword.get(opts, :env_fallback, true)

    if prefer_env do
      case fetch_env(name, opts) do
        {:ok, value} -> {:ok, value, :env}
        :error -> resolve_from_store(name, env_fallback, opts)
      end
    else
      resolve_from_store(name, env_fallback, opts)
    end
  end

  @spec exists?(name(), keyword()) :: boolean()
  def exists?(name, opts \\ []) do
    prefer_env = Keyword.get(opts, :prefer_env, false)
    env_fallback = Keyword.get(opts, :env_fallback, true)

    cond do
      prefer_env and match?({:ok, _}, fetch_env(name, opts)) ->
        true

      store_exists?(name, opts) ->
        true

      env_fallback ->
        match?({:ok, _}, fetch_env(name, opts))

      true ->
        false
    end
  end

  @spec delete(name(), keyword()) :: :ok | {:error, atom()}
  def delete(name, opts \\ []) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts) do
      :ok = Store.delete(@table, {owner, name})
      emit_secret_event(owner, name, :delete)
      :ok
    end
  end

  @spec list(keyword()) :: {:ok, [secret_metadata()]}
  def list(opts \\ []) do
    owner = owner_from_opts(opts)

    records =
      @table
      |> Store.list()
      |> Enum.reduce([], fn
        {{record_owner, name}, entry}, acc when record_owner == owner ->
          if expired?(entry) do
            :ok = Store.delete(@table, {record_owner, name})
            acc
          else
            [metadata(record_owner, name, entry) | acc]
          end

        _, acc ->
          acc
      end)
      |> Enum.sort_by(& &1.name)

    {:ok, records}
  end

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    {:ok, entries} = list(opts)
    key_status = MasterKey.status(opts)

    %{
      configured: key_status.configured,
      source: key_status.source,
      keychain_available: key_status.keychain_available,
      env_fallback: key_status.env_fallback,
      keychain_error: key_status.keychain_error,
      owner: owner_from_opts(opts),
      count: length(entries)
    }
  end

  defp resolve_from_store(name, env_fallback, opts) do
    case get(name, opts) do
      {:ok, value} ->
        {:ok, value, :store}

      {:error, reason} ->
        if env_fallback do
          case fetch_env(name, opts) do
            {:ok, value} -> {:ok, value, :env}
            :error -> {:error, reason}
          end
        else
          {:error, reason}
        end
    end
  end

  defp store_exists?(name, opts) do
    with {:ok, normalized_name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, _entry} <- fetch_active_entry(owner, normalized_name) do
      true
    else
      _ -> false
    end
  end

  defp fetch_active_entry(owner, name) do
    case Store.get(@table, {owner, name}) do
      nil ->
        {:error, :not_found}

      entry ->
        if expired?(entry) do
          :ok = Store.delete(@table, {owner, name})
          {:error, :expired}
        else
          {:ok, entry}
        end
    end
  end

  defp touch_entry(owner, name, entry) do
    now = Clock.now_ms()

    updated =
      entry
      |> put_field(:usage_count, (get_field(entry, :usage_count) || 0) + 1)
      |> put_field(:last_used_at, now)
      |> put_field(:updated_at, now)

    :ok = Store.put(@table, {owner, name}, updated)
  end

  defp metadata(owner, name, entry) do
    %{
      owner: owner,
      name: name,
      provider: get_field(entry, :provider) || @default_provider,
      expires_at: get_field(entry, :expires_at),
      usage_count: get_field(entry, :usage_count) || 0,
      last_used_at: get_field(entry, :last_used_at),
      created_at: get_field(entry, :created_at) || 0,
      updated_at: get_field(entry, :updated_at) || 0,
      version: get_field(entry, :version) || Crypto.version()
    }
  end

  defp expired?(entry) do
    expires_at = get_field(entry, :expires_at)

    is_integer(expires_at) and expires_at > 0 and expires_at <= Clock.now_ms()
  end

  defp fetch_env(name, opts) do
    getter = Keyword.get(opts, :env_getter, &System.get_env/1)

    case normalize_name(name) do
      {:ok, normalized_name} ->
        case getter.(normalized_name) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp get_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp put_field(map, key, value) when is_map(map) do
    map
    |> Map.put(key, value)
    |> Map.delete(Atom.to_string(key))
  end

  defp normalize_owner(opts) do
    owner = owner_from_opts(opts)

    if owner == "" do
      {:error, :invalid_owner}
    else
      {:ok, owner}
    end
  end

  defp owner_from_opts(opts) do
    normalize_optional_string(Keyword.get(opts, :owner)) || @default_owner
  end

  defp normalize_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :invalid_secret_name}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_name(_), do: {:error, :invalid_secret_name}

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_optional_integer(_), do: nil

  defp emit_secret_event(owner, name, action) do
    if Code.ensure_loaded?(LemonCore.Bus) do
      event =
        LemonCore.Event.new(:secret_changed, %{
          owner: owner,
          name: name,
          action: action
        })

      LemonCore.Bus.broadcast("system", event)
    end
  rescue
    _ -> :ok
  end
end
