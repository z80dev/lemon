defmodule LemonCore.Secrets do
  @moduledoc """
  Encrypted secrets storage backed by `LemonCore.Store`.

  Secret values are encrypted at rest and never returned by list/status APIs.

  ## Master key

  Values are encrypted with AES-256-GCM under a per-secret key derived from the
  master key (`LemonCore.Secrets.Crypto`). Where that master key comes from —
  system keychain, environment variable, key file, or a provider you supply —
  is configurable; see `LemonCore.Secrets.KeyProvider`.

      config :lemon_core, LemonCore.Secrets,
        key_providers: [:keychain, :env, :file],
        key_file: "~/.lemon/secrets_master_key",
        env_var: "LEMON_SECRETS_MASTER_KEY"

  ## Key rotation

  `LemonCore.Secrets.KeyRotation` replaces the master key and re-encrypts
  every stored secret under it (`lemon secrets rotate-key`, or
  `mix lemon.secrets.rotate_key`). It previews first and applies only with the
  preview's confirmation token, refuses to touch anything when a stored secret
  does not decrypt with the current key, refuses while a Lemon runtime is
  running, and keeps every secret decryptable by whichever key is loaded next,
  even if it is interrupted. `set/3`, `set_if_revision/4`, deletion, expiry
  cleanup and rotation share `LemonCore.Secrets.Lock`, so a write never lands
  under a key being retired. Only the encrypted store is rotated; external
  sources and environment fallback are untouched.

  Replacing the key by other means (`mix lemon.secrets.init --force`, editing
  the key file or Keychain entry) still makes every stored secret undecryptable.
  """

  alias LemonCore.Clock
  alias LemonCore.MapHelpers
  alias LemonCore.Secrets.{Crypto, External, KeyRotation, Lock, MasterKey}
  alias LemonCore.Store

  @table :secrets_v1
  @default_owner "default"
  @default_provider "manual"

  @type owner :: String.t()
  @type name :: String.t()
  @type error_reason :: atom() | tuple()
  @opaque revision :: binary()

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

  @doc """
  Encrypts `value` under the current master key and stores it.

  Holds `LemonCore.Secrets.Lock` from resolving the key until the record is
  stored, so a write never lands under a key a concurrent rotation is
  retiring. Returns `{:error, :secrets_locked}` if a live holder keeps the
  lock for longer than the wait, or `{:error, {:secrets_lock_held, host}}`
  for a lease from another host; callers must report either, not succeed.
  """
  @spec set(name(), String.t(), keyword()) ::
          {:ok, secret_metadata()} | {:error, error_reason()}
  def set(name, value, opts \\ [])

  def set(name, value, opts) when is_binary(value) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts) do
      Lock.with_write_lock(fn -> store_secret(server, owner, name, value, opts) end, server)
    end
  end

  def set(_, _, _), do: {:error, :invalid_secret_value}

  defp store_secret(server, owner, name, value, opts) do
    with {:ok, existing} <- Store.fetch(server, @table, {owner, name}),
         {:ok, record} <- encrypt_record(existing, value, opts),
         :ok <- Store.put(server, @table, {owner, name}, record) do
      emit_secret_event(owner, name, :set)
      {:ok, metadata(owner, name, record)}
    end
  end

  defp encrypt_record(existing, value, opts) do
    with {:ok, master_key, _source} <- MasterKey.resolve(opts),
         {:ok, encrypted} <- Crypto.encrypt(value, master_key) do
      now = Clock.now_ms()

      {:ok,
       %{
         ciphertext: encrypted.ciphertext,
         nonce: encrypted.nonce,
         salt: encrypted.salt,
         incarnation: Base.encode64(:crypto.strong_rand_bytes(32)),
         provider: normalize_optional_string(Keyword.get(opts, :provider)) || @default_provider,
         expires_at: normalize_optional_integer(Keyword.get(opts, :expires_at)),
         usage_count: 0,
         last_used_at: nil,
         created_at: get_field(existing || %{}, :created_at) || now,
         updated_at: now,
         version: encrypted.version
       }}
    end
  end

  @spec get(name(), keyword()) :: {:ok, String.t()} | {:error, error_reason()}
  def get(name, opts \\ []) do
    case get_with_revision(name, opts) do
      {:ok, plaintext, _revision} -> {:ok, plaintext}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Reads only the encrypted store and returns an opaque conditional-write revision.

  The revision binds the storage process, owner, name and durable credential
  incarnation. Usage reads do not invalidate it; replacement (even with the
  same plaintext), deletion/recreation and a storage restart do. Treat it as
  ephemeral credential-bearing data: do not inspect, log or persist it.

  Reads distinguish storage failure from absence and never remove expired
  records. Only a best-effort, exact-snapshot usage touch writes during a read.
  `:store` selects a Store instance; it defaults to `LemonCore.Store`.
  """
  @spec get_with_revision(name(), keyword()) ::
          {:ok, String.t(), revision()} | {:error, error_reason()}
  def get_with_revision(name, opts \\ []) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts),
         {:ok, entry} <- fetch_active_entry(server, owner, name),
         {:ok, master_key, _source} <- MasterKey.resolve(opts),
         {:ok, plaintext} <- KeyRotation.decrypt(entry, master_key) do
      revision = entry_revision(server, owner, name, entry)
      touch_entry(server, owner, name, entry)
      {:ok, plaintext, revision}
    end
  end

  @doc """
  Replaces a credential only if `revision` still identifies its incarnation.

  Uses the same mutation lease as `set/3`, deletion and key rotation, then an
  atomic Store compare-and-swap. Missing, expired or replaced credentials return
  `{:error, :stale_revision}`. Persistence failures are returned, not acknowledged
  as saves. A successful write invalidates the supplied revision.
  """
  @spec set_if_revision(name(), String.t(), revision(), keyword()) ::
          {:ok, secret_metadata()} | {:error, error_reason()}
  def set_if_revision(name, value, revision, opts \\ [])

  def set_if_revision(name, value, revision, opts) when is_binary(value) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts) do
      Lock.with_write_lock(
        fn ->
          with {:ok, entry} <- fetch_revision_entry(server, owner, name, revision),
               {:ok, record} <- encrypt_record(entry, value, opts) do
            swap_revision(server, owner, name, revision, entry, record)
          end
        end,
        server
      )
    end
  end

  def set_if_revision(_, _, _, _), do: {:error, :invalid_secret_value}

  defp swap_revision(server, owner, name, revision, entry, record) do
    # Key resolution may have blocked since the active-entry read. Recheck
    # immediately before every CAS, including retries after usage touches.
    if expired_entry?(entry) do
      {:error, :stale_revision}
    else
      case Store.compare_and_swap(server, @table, {owner, name}, entry, record) do
        :ok ->
          emit_secret_event(owner, name, :set)
          {:ok, metadata(owner, name, record)}

        {:error, :mismatch} ->
          # Usage touches can race the exact-record CAS. Re-fetch strictly and
          # continue only while the original incarnation is still current.
          with {:ok, current} <- fetch_revision_entry(server, owner, name, revision) do
            swap_revision(server, owner, name, revision, current, record)
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp fetch_revision_entry(server, owner, name, revision) do
    with {:ok, entry} <- fetch_active_entry(server, owner, name) do
      if is_binary(revision) and entry_revision(server, owner, name, entry) == revision,
        do: {:ok, entry},
        else: {:error, :stale_revision}
    else
      {:error, reason} when reason in [:not_found, :expired] -> {:error, :stale_revision}
      {:error, _reason} = error -> error
    end
  end

  defp entry_revision(server, owner, name, entry) do
    # Legacy records need no migration write on read. Their encrypted snapshot
    # identifies the incarnation until the next normal replacement.
    incarnation =
      get_field(entry, :incarnation) ||
        Enum.map([:ciphertext, :nonce, :salt, :version, :created_at, :updated_at], fn key ->
          get_field(entry, key)
        end)

    :crypto.hash(:sha256, :erlang.term_to_binary({server, owner, name, incarnation}))
  end

  defp storage_owner(opts) do
    case GenServer.whereis(Keyword.get(opts, :store, Store)) do
      server when is_pid(server) -> {:ok, server}
      nil -> {:error, :store_unavailable}
    end
  end

  @doc """
  Convenience wrapper around `resolve/2` that returns just the value or `nil`.

  Drop-in replacement for `System.get_env/1` — tries the encrypted store first,
  then falls back to the environment variable of the same name.

      iex> LemonCore.Secrets.fetch_value("ANTHROPIC_API_KEY")
      "sk-ant-..."

      iex> LemonCore.Secrets.fetch_value("MISSING_KEY")
      nil
  """
  @spec fetch_value(name(), keyword()) :: String.t() | nil
  def fetch_value(name, opts \\ []) do
    case resolve(name, opts) do
      {:ok, value, _source} -> value
      {:error, _reason} -> nil
    end
  end

  @spec resolve(name(), keyword()) ::
          {:ok, String.t(), :store | :env | String.t()} | {:error, error_reason()}
  def resolve(name, opts \\ []) do
    prefer_env = Keyword.get(opts, :prefer_env, false)
    env_fallback = Keyword.get(opts, :env_fallback, true)
    external_fallback = Keyword.get(opts, :external_fallback, env_fallback)

    if prefer_env do
      case fetch_env(name, opts) do
        {:ok, value} -> {:ok, value, :env}
        :error -> resolve_from_store(name, external_fallback, env_fallback, opts)
      end
    else
      resolve_from_store(name, external_fallback, env_fallback, opts)
    end
  end

  @doc """
  Resolves only the encrypted store and same-name environment fallback.

  External-source implementations use this for bootstrap credentials so a
  source can never recurse through itself or another external source.
  """
  @spec resolve_local(name(), keyword()) ::
          {:ok, String.t(), :store | :env} | {:error, error_reason()}
  def resolve_local(name, opts \\ []) do
    prefer_env = Keyword.get(opts, :prefer_env, false)
    env_fallback = Keyword.get(opts, :env_fallback, true)

    if prefer_env do
      case fetch_env(name, opts) do
        {:ok, value} -> {:ok, value, :env}
        :error -> resolve_from_store_local(name, env_fallback, opts)
      end
    else
      resolve_from_store_local(name, env_fallback, opts)
    end
  end

  @spec exists?(name(), keyword()) :: boolean()
  def exists?(name, opts \\ []) do
    match?({:ok, _value, _source}, resolve(name, opts))
  end

  @doc "Checks only the encrypted store and same-name environment fallback."
  @spec exists_local?(name(), keyword()) :: boolean()
  def exists_local?(name, opts \\ []) do
    prefer_env = Keyword.get(opts, :prefer_env, false)
    env_fallback = Keyword.get(opts, :env_fallback, true)

    (prefer_env and match?({:ok, _}, fetch_env(name, opts))) or
      store_exists?(name, opts) or
      (env_fallback and match?({:ok, _}, fetch_env(name, opts)))
  end

  @doc """
  Persist a secret to the encrypted store.

  This is an alias for `set/3` that provides a consistent API for
  modules that need a `persist/2` function.

  ## Examples

      iex> LemonCore.Secrets.persist("MY_API_KEY", "sk-...")
      {:ok, %{name: "MY_API_KEY", ...}}
  """
  @spec persist(name(), String.t(), keyword()) ::
          {:ok, secret_metadata()} | {:error, error_reason()}
  def persist(name, value, opts \\ []) do
    set(name, value, opts)
  end

  @doc """
  Import a secret from an environment variable into the encrypted store.

  ## Options

    * `:env_name` - The environment variable name (defaults to secret name)
    * `:delete_after` - If true, deletes the env var after import (default: false)
    * Other options are passed to `set/3`

  ## Examples

      iex> System.put_env("OLD_API_KEY", "sk-...")
      iex> LemonCore.Secrets.import_from_env("NEW_API_KEY", env_name: "OLD_API_KEY")
      {:ok, %{name: "NEW_API_KEY", ...}}
  """
  @spec import_from_env(name(), keyword()) ::
          {:ok, secret_metadata()} | {:error, error_reason()}
  def import_from_env(name, opts \\ []) do
    env_name = Keyword.get(opts, :env_name, name)
    delete_after = Keyword.get(opts, :delete_after, false)

    case System.get_env(env_name) do
      nil ->
        {:error, :env_not_found}

      "" ->
        {:error, :env_empty}

      value ->
        result = set(name, value, opts)

        if delete_after and match?({:ok, _}, result) do
          System.delete_env(env_name)
        end

        result
    end
  end

  @spec delete(name(), keyword()) :: :ok | {:error, error_reason()}
  def delete(name, opts \\ []) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts),
         {:ok, entry} <- Store.fetch(server, @table, {owner, name}) do
      if is_nil(entry) do
        :ok
      else
        Lock.with_write_lock(
          fn ->
            case Store.compare_and_delete_many(server, [{@table, {owner, name}, entry}]) do
              :ok ->
                emit_secret_event(owner, name, :delete)
                :ok

              {:error, :mismatch} ->
                {:error, :stale_revision}

              {:error, _reason} = error ->
                error
            end
          end,
          server
        )
      end
    end
  end

  @spec list(keyword()) :: {:ok, [secret_metadata()]} | {:error, error_reason()}
  def list(opts \\ []) do
    with {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts),
         {:ok, rows} <- Store.fetch_all(server, @table) do
      rows
      |> Enum.reduce_while({:ok, []}, fn
        {{record_owner, name}, entry}, {:ok, acc} when record_owner == owner ->
          if expired_entry?(entry) do
            case remove_expired(server, record_owner, name, entry) do
              :ok -> {:cont, {:ok, acc}}
              {:error, _reason} = error -> {:halt, error}
            end
          else
            {:cont, {:ok, [metadata(record_owner, name, entry) | acc]}}
          end

        _, acc ->
          {:cont, acc}
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.sort_by(records, & &1.name)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp remove_expired(server, owner, name, entry) do
    Lock.with_write_lock(
      fn ->
        case Store.compare_and_delete_many(server, [{@table, {owner, name}, entry}]) do
          :ok -> :ok
          {:error, :mismatch} -> :ok
          {:error, _reason} = error -> error
        end
      end,
      server
    )
  end

  @spec status(keyword()) :: map() | {:error, error_reason()}
  def status(opts \\ []) do
    with {:ok, entries} <- list(opts) do
      key_status = MasterKey.status(opts)

      %{
        configured: key_status.configured,
        source: key_status.source,
        keychain_available: key_status.keychain_available,
        env_fallback: key_status.env_fallback,
        file_fallback: key_status.file_fallback,
        keychain_error: key_status.keychain_error,
        providers: key_status.providers,
        key_file: key_status.key_file,
        owner: owner_from_opts(opts),
        count: length(entries)
      }
    end
  end

  defp resolve_from_store(name, external_fallback, env_fallback, opts) do
    case get(name, opts) do
      {:ok, value} ->
        {:ok, value, :store}

      {:error, reason} ->
        resolve_after_store(name, reason, external_fallback, env_fallback, opts)
    end
  end

  defp resolve_after_store(name, store_reason, true, env_fallback, opts) do
    case External.resolve(name, opts) do
      {:ok, value, provenance} -> {:ok, value, provenance}
      {:error, :not_found} -> maybe_resolve_env(name, store_reason, env_fallback, opts)
      {:error, reason} -> {:error, {:external_source, reason}}
    end
  end

  defp resolve_after_store(name, store_reason, false, env_fallback, opts) do
    maybe_resolve_env(name, store_reason, env_fallback, opts)
  end

  defp resolve_from_store_local(name, env_fallback, opts) do
    case get(name, opts) do
      {:ok, value} -> {:ok, value, :store}
      {:error, reason} -> maybe_resolve_env(name, reason, env_fallback, opts)
    end
  end

  defp maybe_resolve_env(name, reason, true, opts) do
    case fetch_env(name, opts) do
      {:ok, value} -> {:ok, value, :env}
      :error -> {:error, reason}
    end
  end

  defp maybe_resolve_env(_name, reason, false, _opts), do: {:error, reason}

  defp store_exists?(name, opts) do
    with {:ok, normalized_name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts),
         {:ok, _entry} <- fetch_active_entry(server, owner, normalized_name) do
      true
    else
      _ -> false
    end
  end

  defp fetch_active_entry(server, owner, name) do
    case Store.fetch(server, @table, {owner, name}) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, entry} when is_map(entry) ->
        if expired_entry?(entry), do: {:error, :expired}, else: {:ok, entry}

      {:ok, _invalid} ->
        {:error, :invalid_secret_record}

      {:error, _reason} = error ->
        error
    end
  end

  # Compare-and-swap so a read never writes back a record that changed after it
  # was fetched (a concurrent `set/3`, or a key rotation staging ciphertext).
  # Usage metadata is best effort: losing a race only skips the count.
  defp touch_entry(server, owner, name, entry) do
    now = Clock.now_ms()

    updated =
      entry
      |> put_field(:usage_count, (get_field(entry, :usage_count) || 0) + 1)
      |> put_field(:last_used_at, now)

    _ = Store.compare_and_swap(server, @table, {owner, name}, entry, updated)
    :ok
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

  @doc false
  @spec expired_entry?(map()) :: boolean()
  def expired_entry?(entry) do
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
    MapHelpers.get_key(map, key)
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
        LemonCore.Event.new(
          :secret_changed,
          LemonCore.Events.SecretChanged.new(%{owner: owner, name: name, action: action})
        )

      LemonCore.Bus.broadcast("system", event)
    end
  rescue
    _ -> :ok
  end
end
