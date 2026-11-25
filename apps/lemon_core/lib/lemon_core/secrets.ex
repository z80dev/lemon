defmodule LemonCore.Secrets do
  @moduledoc """
  Encrypted secrets storage backed by `LemonCore.Store`.

  Secret values are encrypted at rest and never returned by list/status APIs.

  ## Master key

  Values are encrypted with AES-256-GCM under a per-secret key derived from the
  master key (`LemonCore.Secrets.Crypto`). Where that master key comes from —
  system keychain, environment variable, key file, or a provider you supply —
  is configurable; see `LemonCore.Secrets.KeyProvider`.

      config :lemon_core, :secrets,
        key_providers: [:keychain, :env, :file],
        key_file: "~/.lemon/secrets_master_key",
        env_var: "LEMON_SECRETS_MASTER_KEY"

  ## Key rotation

  An operator-initiated key rotation replaces the master key and re-encrypts
  every stored secret under it (`lemon secrets rotate-key`). It previews first
  and applies only with the preview's confirmation token, refuses to touch
  anything when a stored secret does not decrypt with the current key, refuses
  while a Lemon runtime is running, and keeps every secret decryptable by
  whichever key is loaded next, even if it is interrupted. `set/3`,
  `set_if_revision/4`, deletion, expiry cleanup and rotation share
  `LemonCore.Secrets.Lock`, so a write never lands under a key being retired.
  Only the encrypted store is rotated; external sources and environment
  fallback are untouched.

  Replacing the key by other means (`lemon secrets init --force`, editing
  the key file or Keychain entry) still makes every stored secret undecryptable.
  """

  alias LemonCore.Clock
  alias LemonCore.MapHelpers

  alias LemonCore.Secrets.{
    Crypto,
    External,
    KeyCheck,
    Lock,
    MasterKey,
    Receipts,
    Record,
    Usage
  }

  alias LemonCore.Store

  @table Record.table()
  @default_owner "default"
  @default_provider "manual"

  @type owner :: String.t()
  @type name :: String.t()
  @type error_reason :: atom() | tuple()
  @opaque revision :: binary()
  @opaque snapshot :: {pid(), owner(), name(), String.t(), map()}

  @type secret_metadata :: %{
          required(:owner) => owner(),
          required(:name) => name(),
          required(:provider) => String.t(),
          required(:expires_at) => integer() | nil,
          required(:usage_count) => non_neg_integer(),
          required(:last_used_at) => integer() | nil,
          required(:created_at) => integer(),
          required(:updated_at) => integer(),
          required(:version) => String.t(),
          optional(:operation_id) => String.t(),
          optional(:status) => String.t(),
          optional(:current_binding_matches) => boolean(),
          optional(:incarnation) => String.t()
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
  With `:operation_id` and authenticated `:node_id`, the same row also stores a
  private durable receipt. An identical operation returns without writing;
  changed intent or a superseded binding returns `:secret_operation_conflict`.
  Receipt capacity is bounded and never evicts historical proof.
  """
  @spec set(name(), String.t(), keyword()) ::
          {:ok, secret_metadata()} | {:error, error_reason()}
  def set(name, value, opts \\ [])

  def set(name, value, opts) when is_binary(value) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         :ok <- validate_operation(opts),
         {:ok, server} <- storage_owner(opts) do
      Lock.with_write_lock(fn -> store_secret(server, owner, name, value, opts) end, server)
    end
  end

  def set(_, _, _), do: {:error, :invalid_secret_value}

  @doc """
  Stores `value` only when `name` has no stored value, like `set/3` otherwise.

  The existence check and the write run under the same
  `LemonCore.Secrets.Lock` lease as every other secret write, so a concurrent
  `set/3` or `create/3` can never be silently replaced. Returns
  `{:error, :already_exists}` when any value (including an expired one) exists.
  On success the metadata also carries `:incarnation`, an opaque durable
  identifier of exactly this stored value for `delete_if_incarnation/3`.
  """
  @spec create(name(), String.t(), keyword()) ::
          {:ok, secret_metadata()} | {:error, error_reason()}
  def create(name, value, opts \\ [])

  def create(name, value, opts) when is_binary(value) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         :ok <- validate_operation(opts),
         {:ok, server} <- storage_owner(opts) do
      Lock.with_write_lock(
        fn ->
          with {:ok, entry} <- Store.fetch(server, @table, {owner, name}),
               :ok <- ensure_absent_value(entry),
               {:ok, metadata} <- store_secret(server, owner, name, value, opts),
               {:ok, stored} <- Store.fetch(server, @table, {owner, name}) do
            {:ok, Map.put(metadata, :incarnation, get_field(stored || %{}, :incarnation))}
          end
        end,
        server
      )
    end
  end

  def create(_, _, _), do: {:error, :invalid_secret_value}

  defp ensure_absent_value(nil), do: :ok

  defp ensure_absent_value(entry),
    do: if(Receipts.receipt_only?(entry), do: :ok, else: {:error, :already_exists})

  @doc """
  Deletes `name` only if its stored value is still the incarnation returned by
  `create/3`. Unlike revisions, incarnations are durable across Store
  processes, so a later process can compensate exactly the value it created.
  A replaced, rotated or missing value returns `{:error, :stale_revision}` and
  is left untouched.
  """
  @spec delete_if_incarnation(name(), String.t(), keyword()) :: :ok | {:error, error_reason()}
  def delete_if_incarnation(name, incarnation, opts \\ []) when is_binary(incarnation) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts) do
      Lock.with_write_lock(
        fn ->
          with {:ok, entry} <- Store.fetch(server, @table, {owner, name}),
               true <-
                 (Record.value?(entry || %{}) and get_field(entry, :incarnation) == incarnation) ||
                   {:error, :stale_revision},
               {:ok, rows} <- fetch_receipt_rows(server),
               {:ok, _} <- Receipts.find(rows, owner, nil, nil) do
            case remove_value(server, owner, name, entry) do
              :ok ->
                emit_secret_event(owner, name, :delete)
                :ok

              {:error, :mismatch} ->
                {:error, :stale_revision}

              {:error, _reason} = error ->
                error
            end
          end
        end,
        server
      )
    end
  end

  defp validate_operation(opts) do
    if Keyword.has_key?(opts, :operation_id) do
      with :ok <- Receipts.operation_id(opts[:operation_id]),
           do: Receipts.node_id(opts[:node_id])
    else
      :ok
    end
  end

  defp store_secret(server, owner, name, value, opts) do
    with {:ok, existing} <- Store.fetch(server, @table, {owner, name}),
         {:ok, rows} <- fetch_receipt_rows(server),
         {:ok, found} <- operation_receipt(rows, owner, opts),
         {:ok, master_key, _source} <- MasterKey.resolve_fresh(opts),
         :ok <- KeyCheck.ensure(server, rows, master_key) do
      provider = normalize_optional_string(opts[:provider]) || @default_provider
      expires_at = normalize_optional_integer(opts[:expires_at])

      case found do
        nil ->
          write_secret(server, owner, name, value, existing, master_key, opts)

        {^name, entry, receipt} ->
          intent =
            Receipts.intent(master_key, owner, opts[:node_id], name, value, provider, expires_at)

          if Receipts.current?(entry, receipt) and Receipts.same_intent?(receipt, intent),
            do: {:ok, operation_metadata(owner, name, entry, opts)},
            else: {:error, :secret_operation_conflict}

        _ ->
          {:error, :secret_operation_conflict}
      end
    end
  end

  defp write_secret(server, owner, name, value, existing, master_key, opts) do
    with {:ok, record} <- encrypt_record(existing, value, master_key, opts),
         {:ok, record} <- append_receipt(record, owner, name, value, master_key, opts),
         :ok <- persist_record(server, owner, name, record, opts) do
      emit_secret_event(owner, name, :set)
      {:ok, operation_metadata(owner, name, record, opts)}
    end
  end

  defp append_receipt(record, owner, name, value, key, opts) do
    if Keyword.has_key?(opts, :operation_id) do
      receipt = %{
        node_id: opts[:node_id],
        operation_id: opts[:operation_id],
        intent:
          Receipts.intent(
            key,
            owner,
            opts[:node_id],
            name,
            value,
            record.provider,
            record.expires_at
          ),
        binding: Receipts.binding(record)
      }

      Receipts.append(record, receipt)
    else
      {:ok, record}
    end
  end

  defp operation_metadata(owner, name, record, opts) do
    result = metadata(owner, name, record)

    if Keyword.has_key?(opts, :operation_id) do
      Map.merge(result, %{
        operation_id: opts[:operation_id],
        status: "applied",
        current_binding_matches: not Record.expired?(record)
      })
    else
      result
    end
  end

  defp operation_receipt(rows, owner, opts) do
    # Validate all receipts for this owner even for ordinary writes, so
    # malformed persisted proof cannot be discarded by overwriting its row.
    Receipts.find(rows, owner, opts[:node_id], opts[:operation_id])
  end

  defp fetch_receipt_rows(server) do
    case Record.fetch_rows(server) do
      {:ok, rows} -> {:ok, rows}
      {:error, _} -> {:error, :secret_store_failed}
    end
  end

  defp persist_record(server, owner, name, record, opts) do
    case Store.put(server, @table, {owner, name}, record) do
      :ok ->
        :ok

      {:error, _} = error ->
        if Keyword.has_key?(opts, :operation_id),
          do: {:error, :secret_store_failed},
          else: error
    end
  end

  @doc """
  Read-only durable proof for an operation on the authenticated `:node_id`.
  Does not resolve a master key, decrypt a value, replay a set, or touch usage.
  `applied` is historical proof; `current_binding_matches` also requires the
  original encrypted revision to remain active and unexpired.
  """
  @spec receipt(String.t(), keyword()) :: {:ok, map()} | {:error, error_reason()}
  def receipt(operation_id, opts \\ []) do
    with :ok <- Receipts.operation_id(operation_id),
         :ok <- Receipts.node_id(opts[:node_id]),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts) do
      Lock.with_write_lock(
        fn ->
          with {:ok, rows} <- fetch_receipt_rows(server),
               {:ok, found} <- Receipts.find(rows, owner, opts[:node_id], operation_id) do
            {:ok, Receipts.proof(opts[:node_id], operation_id, found)}
          end
        end,
        server
      )
    end
  end

  defp encrypt_record(existing, value, master_key, opts) do
    with {:ok, encrypted} <- Crypto.encrypt(value, master_key) do
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
         version: encrypted.version,
         receipts: Receipts.entries(existing || %{})
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
  records. Best-effort, exact-snapshot usage touches are cast to a batching worker.
  `:store` selects a Store instance; it defaults to `LemonCore.Store`.
  """
  @spec get_with_revision(name(), keyword()) ::
          {:ok, String.t(), revision()} | {:error, error_reason()}
  def get_with_revision(name, opts \\ []) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts),
         {:ok, entry} <- fetch_active_entry(server, owner, name),
         {:ok, entry, plaintext} <- decrypt_entry(server, owner, name, entry, opts) do
      if Record.expired?(entry) do
        {:error, :expired}
      else
        revision = entry_revision(server, owner, name, entry)
        Usage.touch(server, {owner, name}, entry)
        {:ok, plaintext, revision}
      end
    end
  end

  @doc """
  Captures a credential and its metadata for compensating a serialized mutation.

  Reads only the encrypted store, without touching usage metadata. Expired values
  can be captured too, so compensation preserves their original expiry. Snapshots
  are opaque, ephemeral credential-bearing data: never log, inspect or persist
  them. The caller must serialize its whole mutation and compensation sequence.
  """
  @spec snapshot(name(), keyword()) :: {:ok, snapshot()} | {:error, error_reason()}
  def snapshot(name, opts \\ []) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts),
         {:ok, entry} <- Store.fetch(server, @table, {owner, name}) do
      cond do
        is_nil(entry) or Receipts.receipt_only?(entry) ->
          {:error, :not_found}

        not Record.value?(entry) ->
          {:error, :invalid_secret_record}

        true ->
          with {:ok, entry, plaintext} <- decrypt_entry(server, owner, name, entry, opts) do
            {:ok, {server, owner, name, plaintext, entry}}
          end
      end
    end
  end

  @doc """
  Restores a snapshot to its original Store process, owner and name.

  Re-encrypts under the current key while holding the secrets mutation lease.
  Provider, absolute expiry, timestamps and usage metadata are preserved, even
  when expiry elapsed during the failed operation. Restoration creates a new
  incarnation, so it never revives a previous conditional-write revision.
  """
  @spec restore(name(), snapshot(), keyword()) ::
          {:ok, secret_metadata()} | {:error, error_reason()}
  def restore(name, snapshot, opts \\ []) do
    with {:ok, name} <- normalize_name(name),
         {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts) do
      case snapshot do
        {^server, ^owner, ^name, value, entry} when is_binary(value) and is_map(entry) ->
          Lock.with_write_lock(
            fn ->
              with {:ok, rows} <- fetch_receipt_rows(server),
                   {:ok, _} <- Receipts.find(rows, owner, nil, nil),
                   {:ok, master_key, _source} <- MasterKey.resolve_fresh(opts),
                   :ok <- KeyCheck.ensure(server, rows, master_key),
                   {:ok, encrypted} <- encrypt_record(entry, value, master_key, []) do
                record =
                  Enum.reduce(
                    [
                      :provider,
                      :expires_at,
                      :created_at,
                      :updated_at,
                      :usage_count,
                      :last_used_at
                    ],
                    encrypted,
                    fn key, acc -> Map.put(acc, key, get_field(entry, key)) end
                  )

                with :ok <- persist_record(server, owner, name, record, []) do
                  emit_secret_event(owner, name, :set)
                  {:ok, metadata(owner, name, record)}
                end
              end
            end,
            server
          )

        _ ->
          {:error, :invalid_secret_snapshot}
      end
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
               {:ok, rows} <- fetch_receipt_rows(server),
               {:ok, _} <- Receipts.find(rows, owner, nil, nil),
               {:ok, master_key, _source} <- MasterKey.resolve_fresh(opts),
               :ok <- KeyCheck.ensure(server, rows, master_key),
               {:ok, record} <- encrypt_record(entry, value, master_key, opts) do
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
    if Record.expired?(entry) do
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
    case fetch_active_entry(server, owner, name) do
      {:ok, entry} ->
        if is_binary(revision) and entry_revision(server, owner, name, entry) == revision,
          do: {:ok, entry},
          else: {:error, :stale_revision}

      {:error, reason} when reason in [:not_found, :expired] ->
        {:error, :stale_revision}

      {:error, _reason} = error ->
        error
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
  then enabled external sources, then the environment variable of the same
  name. Any failure, including a store or source error, returns `nil`; callers
  must not substitute an environment read of their own.

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

  @doc """
  Resolves a secret: encrypted store, then enabled external sources, then the
  same-name environment variable.

  Only a definite store miss (`:not_found`) continues past the store. Every
  other store failure — an undecryptable or malformed record, a store,
  master-key or lock outage — is returned as `{:error, reason}`; an external
  source failure or an invalid `[secrets]` table is returned as
  `{:error, {:external_source, reason}}`. Neither ever falls back to the
  environment.

  ## Options

    * `:prefer_env` - read the environment before the store (default `false`)
    * `:env_fallback` - read the environment after a miss (default `true`)
    * `:external_fallback` - consult enabled external sources after a store
      miss (default `true`, independent of `:env_fallback`)
    * `:expired_fallback` - treat an expired store record as a miss instead
      of returning `{:error, :expired}` (default `false`)
  """
  @spec resolve(name(), keyword()) ::
          {:ok, String.t(), :store | :env | String.t()} | {:error, error_reason()}
  def resolve(name, opts \\ []) do
    prefer_env = Keyword.get(opts, :prefer_env, false)
    env_fallback = Keyword.get(opts, :env_fallback, true)
    external_fallback = Keyword.get(opts, :external_fallback, true)

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
  source can never recurse through itself or another external source. Store
  errors other than a definite miss fail closed exactly as in `resolve/2`.
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

  @doc "Reports redacted external-source readiness without running a helper."
  def external_status(opts \\ []), do: External.status(opts, &resolve_local(&1, opts))

  @doc "Runs enabled external sources and returns only redacted metadata."
  def test_external(opts \\ []), do: External.test(opts, &resolve_local(&1, opts))

  @spec exists?(name(), keyword()) :: boolean()
  def exists?(name, opts \\ []) do
    match?({:ok, _value, _source}, resolve(name, opts))
  end

  @doc "Checks only the encrypted store and same-name environment fallback."
  @spec exists_local?(name(), keyword()) :: boolean()
  def exists_local?(name, opts \\ []) do
    match?({:ok, _value, _source}, resolve_local(name, opts))
  end

  @doc """
  Side-effect-free presence check following `resolve/2`'s source order.

  Never decrypts a value, runs an external source, records usage or removes an
  expired record. A stored record is `:present` only when the resolvable
  master key is the one the store's key verifier names (a store written before
  verifiers existed cannot be checked without decrypting and counts as
  present). External sources count only when an enabled source declares a
  reference for `name`. Takes `resolve/2`'s options.

  Returns `:present`, `:missing` (a definite absence) or `{:unusable, reason}`
  where `resolve/2` would fail closed (for example `:master_key_mismatch`,
  `:master_key_unavailable`, `:expired` or a store outage).
  """
  @spec presence(name(), keyword()) :: :present | :missing | {:unusable, atom()}
  def presence(name, opts \\ []) do
    case normalize_name(name) do
      {:ok, name} ->
        if Keyword.get(opts, :prefer_env, false) and fetch_env(name, opts) != :error do
          :present
        else
          store_presence(name, opts)
        end

      _ ->
        :missing
    end
  end

  defp store_presence(name, opts) do
    with {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts) do
      case fetch_active_entry(server, owner, name) do
        {:ok, _entry} ->
          key_presence(server, opts)

        {:error, reason} ->
          if store_miss?(reason, opts),
            do: presence_after_store(name, opts),
            else: {:unusable, reason}
      end
    else
      {:error, reason} -> {:unusable, reason}
    end
  rescue
    _ -> {:unusable, :secret_store_failed}
  catch
    :exit, _ -> {:unusable, :secret_store_failed}
  end

  defp key_presence(server, opts) do
    case MasterKey.resolve_cached(opts) do
      {:ok, master_key, _source} ->
        if KeyCheck.matches?(server, master_key) == false,
          do: {:unusable, :master_key_mismatch},
          else: :present

      _ ->
        {:unusable, :master_key_unavailable}
    end
  end

  defp presence_after_store(name, opts) do
    cond do
      Keyword.get(opts, :external_fallback, true) and External.declared?(name, opts) -> :present
      Keyword.get(opts, :env_fallback, true) and fetch_env(name, opts) != :error -> :present
      true -> :missing
    end
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
            with {:ok, rows} <- fetch_receipt_rows(server),
                 {:ok, _} <- Receipts.find(rows, owner, nil, nil) do
              remove_incarnation(server, owner, name, entry)
            end
          end,
          server
        )
      end
    end
  end

  defp remove_incarnation(server, owner, name, entry) do
    case remove_value(server, owner, name, entry) do
      :ok ->
        emit_secret_event(owner, name, :delete)
        :ok

      {:error, :mismatch} ->
        # Usage touches rewrite metadata outside the write lock, so they can
        # race this exact-record CAS. Retry only while the same incarnation is
        # current; a replaced or removed value remains a stale revision.
        revision = entry_revision(server, owner, name, entry)

        case Store.fetch(server, @table, {owner, name}) do
          {:ok, current} when is_map(current) ->
            if entry_revision(server, owner, name, current) == revision,
              do: remove_incarnation(server, owner, name, current),
              else: {:error, :stale_revision}

          {:ok, nil} ->
            {:error, :stale_revision}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec list(keyword()) :: {:ok, [secret_metadata()]} | {:error, error_reason()}
  def list(opts \\ []) do
    with {:ok, owner} <- normalize_owner(opts),
         {:ok, server} <- storage_owner(opts),
         :ok <- Usage.flush(),
         {:ok, rows} <- Record.fetch_rows(server),
         {:ok, _} <- Receipts.find(rows, owner, nil, nil) do
      rows
      |> Enum.reduce_while({:ok, []}, fn
        {{record_owner, name}, entry}, {:ok, acc} when record_owner == owner ->
          cond do
            Receipts.receipt_only?(entry) ->
              {:cont, {:ok, acc}}

            not Record.value?(entry) ->
              {:halt, {:error, :invalid_secret_record}}

            Record.expired?(entry) ->
              case remove_expired(server, record_owner, name, entry) do
                :ok -> {:cont, {:ok, acc}}
                {:error, _reason} = error -> {:halt, error}
              end

            true ->
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
    cond do
      # Receipt-bearing rows retain their historical proof unchanged; expiry
      # already invalidates the current binding and hides the value from reads.
      Receipts.entries(entry) != [] ->
        :ok

      # A one-shot client's store refuses writes; the runtime owning the store
      # prunes the row, and `list/1` still hides it.
      Store.write_access(server) != :ok ->
        :ok

      true ->
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
        if store_miss?(reason, opts),
          do: resolve_after_store(name, reason, external_fallback, env_fallback, opts),
          else: {:error, reason}
    end
  end

  # Only a definite absence may defer to an external source or the
  # environment. Any other failure (unreadable or undecryptable record, store
  # or master-key outage, lock timeout) means a stored credential may exist,
  # and answering with a different identity would hide that failure.
  # An expired record defers only when the caller opts in.
  defp store_miss?(:not_found, _opts), do: true
  defp store_miss?(:expired, opts), do: Keyword.get(opts, :expired_fallback, false) === true
  defp store_miss?(_reason, _opts), do: false

  defp resolve_after_store(name, store_reason, true, env_fallback, opts) do
    case External.resolve(name, opts, &resolve_local(&1, opts)) do
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
      {:ok, value} ->
        {:ok, value, :store}

      {:error, reason} ->
        if store_miss?(reason, opts),
          do: maybe_resolve_env(name, reason, env_fallback, opts),
          else: {:error, reason}
    end
  end

  defp maybe_resolve_env(name, reason, true, opts) do
    case fetch_env(name, opts) do
      {:ok, value} -> {:ok, value, :env}
      :error -> {:error, reason}
    end
  end

  defp maybe_resolve_env(_name, reason, false, _opts), do: {:error, reason}

  # An unchanged record that does not open under a key the store's verifier
  # rejects is the wrong key (`:master_key_mismatch`), not one damaged record.
  # Stores written before verifiers existed fall back to "the key opens no
  # stored record".
  defp decrypt_failure(server, opts) do
    case MasterKey.resolve_cached(opts) do
      {:ok, master_key, _source} ->
        case KeyCheck.matches?(server, master_key) do
          false -> {:error, :master_key_mismatch}
          true -> {:error, :decrypt_failed}
          :unknown -> legacy_decrypt_failure(server, master_key)
        end

      _ ->
        {:error, :decrypt_failed}
    end
  end

  defp legacy_decrypt_failure(server, master_key) do
    case Record.fetch_rows(server) do
      {:ok, rows} ->
        opens_any? =
          Enum.any?(rows, fn {_ref, entry} ->
            is_map(entry) and Record.value?(entry) and
              match?({:ok, _}, Record.decrypt(entry, master_key))
          end)

        if opens_any?, do: {:error, :decrypt_failed}, else: {:error, :master_key_mismatch}

      _ ->
        {:error, :decrypt_failed}
    end
  end

  # A cache miss may wait behind rotation after the caller fetched its snapshot.
  # Re-read only on authentication failure and retry only a changed record; never
  # reuse an old ciphertext with the newly published key or touch a replacement.
  defp decrypt_entry(server, owner, name, entry, opts) do
    with {:ok, master_key, _source} <- MasterKey.resolve_cached(opts),
         {:ok, plaintext} <- Record.decrypt(entry, master_key) do
      {:ok, entry, plaintext}
    else
      {:error, :decrypt_failed} ->
        case Store.fetch(server, @table, {owner, name}) do
          {:ok, ^entry} ->
            decrypt_failure(server, opts)

          {:ok, current} when is_map(current) ->
            cond do
              Receipts.receipt_only?(current) -> {:error, :not_found}
              not Record.value?(current) -> {:error, :invalid_secret_record}
              true -> decrypt_entry(server, owner, name, current, opts)
            end

          {:ok, nil} ->
            {:error, :not_found}

          {:ok, _invalid} ->
            {:error, :invalid_secret_record}

          {:error, _reason} = failure ->
            failure
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_active_entry(server, owner, name) do
    case Store.fetch(server, @table, {owner, name}) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, entry} when is_map(entry) ->
        cond do
          Receipts.receipt_only?(entry) -> {:error, :not_found}
          not Record.value?(entry) -> {:error, :invalid_secret_record}
          Record.expired?(entry) -> {:error, :expired}
          true -> {:ok, entry}
        end

      {:ok, _invalid} ->
        {:error, :invalid_secret_record}

      {:error, _reason} = error ->
        error
    end
  end

  defp remove_value(server, owner, name, entry) do
    if Receipts.entries(entry) != [] do
      Store.compare_and_swap(server, @table, {owner, name}, entry, Receipts.tombstone(entry))
    else
      Store.compare_and_delete_many(server, [{@table, {owner, name}, entry}])
    end
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
