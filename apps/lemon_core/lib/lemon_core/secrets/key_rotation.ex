defmodule LemonCore.Secrets.KeyRotation do
  @moduledoc """
  Master-key rotation for the encrypted secrets store.

  Rotation generates a new master key, re-encrypts every stored secret under
  it, and replaces the key in the provider that supplied the current one (the
  Keychain entry or the key file). Operators run it as
  `lemon secrets rotate-key` or `mix lemon.secrets.rotate_key`.

  ## Preview, then confirm

  `preview/1` changes nothing. It decrypts every live secret with the current
  key and reports how many will be re-encrypted, how many expired records will
  be deleted, and a `confirmation_token`: a SHA-256 digest over the key source,
  a fingerprint of the current key, and every stored `{owner, name}` with its
  ciphertext revision and expiry. `rotate/2` recomputes the digest and refuses
  with `:confirmation_mismatch` when anything changed in between — a secret
  set, deleted or re-encrypted, or the key itself replaced.

  ## Fail closed

  If any live secret does not decrypt with the current key, both functions
  return `{:error, {:undecryptable_secrets, refs}}` (owner and name only) and
  nothing is written. Results, errors and logs never contain secret values or
  key material.

  ## Exclusion

  `rotate/2` refuses with `:runtime_running` while a Lemon runtime answers on
  the control-plane port (`:control_port`, default
  `LemonCore.Runtime.Env.control_port/0`): a runtime started by `bin/lemon`
  exports the master key into its environment at boot and would keep using
  the previous key. It then holds `LemonCore.Secrets.Lock` for the whole
  rotation; `LemonCore.Secrets.set/3` takes the same lock around resolving the
  key and storing the record, so no write lands under a retiring key and two
  rotations never interleave, even from separate OS processes on one store.

  ## Crash safety

  1. **Stage.** Each record keeps its current ciphertext and gains a `staged`
     copy encrypted under the new key (compare-and-swap per record).
  2. **Verify.** Every record is re-read; if the set changed, the staged copies
     are dropped and `:target_changed` is returned.
  3. **Persist.** `LemonCore.Store.sync/1` makes the staged copies durable;
     a backend that cannot confirm it stops the rotation before the key moves.
  4. **Switch.** The new key is written to the provider that supplied the
     current one; the key file is replaced by an atomic rename followed by a
     synchronous directory flush, the Keychain entry is updated in place. A
     key file is rotated only where that flush exists
     (`LemonCore.Secrets.KeyProvider.File.durable_replace/1`); elsewhere,
     including macOS, preview and rotation fail with `:key_file_not_durable`
     before anything is written. The switch counts
     only when the write returned `:ok`, that provider now returns the new key,
     and `LemonCore.Secrets.MasterKey.resolve/1` does too. Otherwise staged
     copies are kept: the write may still land, and records then stay readable
     with either key.
  5. **Converge.** Every record is brought to new-key ciphertext only: staged
     copies are promoted, and any record that only the previous key opens is
     first staged, synced, then promoted. Rotation succeeds only when every
     live record opens with the new key and nothing is left staged.

  Until the switch, the current key decrypts every record's primary
  ciphertext. From then on the new key decrypts either the primary or the
  durable staged ciphertext, and `decrypt/2` (used by `LemonCore.Secrets.get/2`)
  falls back to the staged copy. Whichever key is loaded after an interruption,
  every secret stays readable. A later preview reports such records as
  `resumed`, and the next rotation finishes them.

  ## Scope

  Only the encrypted store is rotated; external sources and environment
  fallback are never touched. A master key supplied by an environment variable
  cannot be rewritten, so rotation refuses with
  `{:error, {:read_only_key_source, :env}}`. Expired records are deleted rather
  than re-encrypted. Store data in older backups stays encrypted under the
  previous key.
  """

  alias LemonCore.MapHelpers
  alias LemonCore.Runtime
  alias LemonCore.Secrets
  alias LemonCore.Secrets.{Crypto, KeyProvider, Lock, MasterKey}
  alias LemonCore.Store

  @token_version "lemon-secrets-rotate-key-v1"
  @fingerprint_info "lemon-secrets-key-fingerprint-v1"
  @cipher_fields [:ciphertext, :nonce, :salt, :version]
  @swap_attempts 3
  @converge_passes 3

  @type secret_ref :: %{owner: String.t() | nil, name: String.t()}

  @type preview :: %{
          source: atom(),
          key_file: Path.t() | nil,
          count: non_neg_integer(),
          expired: non_neg_integer(),
          resumed: non_neg_integer(),
          runtime_running: boolean(),
          confirmation_token: String.t()
        }

  @type result :: %{
          source: atom(),
          key_file: Path.t() | nil,
          rotated: non_neg_integer(),
          pruned: non_neg_integer()
        }

  @doc """
  Decrypts a stored secret record with `master_key`.

  A record left behind by an interrupted rotation also carries a staged
  ciphertext under the next key; it is used when the primary one does not
  open, so the record stays readable with either key.
  """
  @spec decrypt(map(), binary()) :: {:ok, String.t()} | {:error, atom()}
  def decrypt(entry, master_key) do
    case open(entry, master_key) do
      {:ok, plaintext, _via} -> {:ok, plaintext}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Checks that every stored secret decrypts with the current master key and
  returns what `rotate/2` would do, with its confirmation token. Never writes.
  `runtime_running` reports whether `rotate/2` would refuse right now.
  """
  @spec preview(keyword()) :: {:ok, preview()} | {:error, term()}
  def preview(opts \\ []) do
    with {:ok, plan} <- plan(opts) do
      {:ok, Map.put(summary(plan), :runtime_running, runtime_running?(opts))}
    end
  end

  @doc """
  Rotates the master key when `confirmation` equals the token of a preview of
  the current store.

  Errors:

    * `:confirmation_required` / `:confirmation_mismatch` — no or stale token;
      nothing changed.
    * `:runtime_running` — a Lemon runtime is up; nothing changed.
    * `:secrets_locked` — another rotation or secret write holds the lock;
      nothing changed.
    * `{:secrets_lock_held, host}` — a lease from another host holds the
      lock and is never reclaimed automatically; nothing changed.
    * `{:key_file_not_durable, reason}` — the key file cannot be replaced
      durably on this host; nothing changed.
    * `{:undecryptable_secrets, refs}` — nothing changed.
    * `{:read_only_key_source, source}` — the current key cannot be rewritten.
    * `:target_changed` — the store changed during rotation; staged copies were
      dropped and the current key still decrypts every secret.
    * `{:store_not_durable, reason}` — staged copies could not be made durable;
      the key was not touched and the current key decrypts every secret.
    * `{:key_switch_failed, source, reason}` — the provider still holds the
      current key, which decrypts every secret; staged copies under the unused
      new key are kept in case the write lands late.
    * `{:key_switch_unverified, source}` — the new key could not be confirmed;
      every secret is readable with the previous and the new key, and a fresh
      preview shows which one is loaded.
    * `{:promotion_incomplete, count}` — the new key is active; `count` secrets
      are still read through their staged copy until the next rotation.
    * `{:store_failed, reason}` — a Store call failed; whatever was written so
      far keeps every secret readable with the key loaded next.
  """
  @spec rotate(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def rotate(confirmation, opts \\ [])

  def rotate(confirmation, opts) when is_binary(confirmation) and confirmation != "" do
    if runtime_running?(opts) do
      {:error, :runtime_running}
    else
      Lock.with_rotation_lock(fn ->
        with {:ok, plan} <- plan(opts),
             :ok <- confirm(plan, confirmation) do
          execute(plan)
        end
      end)
    end
  end

  def rotate(_confirmation, _opts), do: {:error, :confirmation_required}

  defp runtime_running?(opts) do
    opts
    |> Keyword.get_lazy(:control_port, &Runtime.Env.control_port/0)
    |> Runtime.Health.running?(timeout_ms: 1_000)
  end

  @doc """
  Operator-facing description of a `preview/1` or `rotate/2` error, shared by
  the CLI and the Mix task. Names secrets but never includes values or keys.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(:confirmation_required),
    do: "pass the confirmation token printed by the preview."

  def describe_error(:confirmation_mismatch),
    do:
      "the confirmation token does not match the current secrets store or key; " <>
        "nothing was changed. Preview again for a fresh token."

  def describe_error({:undecryptable_secrets, refs}) do
    names = Enum.map_join(refs, ", ", fn ref -> "#{ref.owner}/#{ref.name}" end)

    "#{length(refs)} stored secret(s) do not decrypt with the current master key; " <>
      "nothing was changed. Delete or re-set them, then preview again: #{names}"
  end

  def describe_error({:read_only_key_source, :env}),
    do:
      "the master key comes from the #{MasterKey.env_var()} environment variable, which " <>
        "Lemon cannot rewrite; nothing was changed. Unset it so the key file or " <>
        "Keychain entry is used, or rotate that variable yourself."

  def describe_error({:read_only_key_source, source}),
    do:
      "the master key comes from #{inspect(source)}, which cannot be rewritten; nothing was changed."

  def describe_error(:missing_master_key),
    do: "no secrets master key is configured; there is nothing to rotate."

  def describe_error(reason) when reason in [:invalid_master_key, :weak_master_key],
    do:
      "the current master key is not valid key material (#{reason}); nothing was changed. " <>
        "Run `lemon secrets status` for diagnostics."

  def describe_error(:target_changed),
    do:
      "the secrets store changed during rotation; the current key still decrypts every " <>
        "secret. Preview again and retry."

  def describe_error({:key_switch_failed, source, reason}),
    do:
      "could not store the new master key in #{source} (#{reason}); #{source} still " <>
        "holds the current key, which decrypts every secret. Preview again and retry."

  def describe_error(:runtime_running),
    do:
      "a Lemon runtime is running and keeps the master key it loaded at boot; nothing " <>
        "was changed. Stop it (`lemon stop`), rotate, then start it again."

  def describe_error(:secrets_locked),
    do:
      "another key rotation or secret write holds the secrets lock; nothing was " <>
        "changed. Retry when it finishes."

  def describe_error({:secrets_lock_held, host}),
    do:
      "the secrets lock is held by a process on #{host} that Lemon cannot check from " <>
        "here; nothing was changed. Once you have confirmed that process is gone, " <>
        "delete the :secrets_lock row from the store and retry."

  def describe_error({:store_not_durable, reason}),
    do:
      "the secrets store could not confirm the re-encrypted secrets are on disk " <>
        "(#{reason}); the key was not changed and still decrypts every secret."

  def describe_error({:key_switch_unverified, source}),
    do:
      "the new master key could not be verified in #{source}; every secret stays " <>
        "readable with both the previous and the new key. Preview again to finish."

  def describe_error({:promotion_incomplete, count}),
    do:
      "the new master key is active, but #{count} secret(s) are still read through " <>
        "their staged copy; preview and rotate again to finish."

  def describe_error({:store_failed, reason}),
    do:
      "the secrets store failed (#{reason}); every secret stays readable with the key " <>
        "loaded next. Preview again and retry."

  def describe_error({:key_file_not_durable, reason}),
    do:
      "the master key is in a key file, and this host cannot make a replaced key file " <>
        "durable (#{reason}); nothing was changed. On macOS keep the master key in the " <>
        "Keychain (the default provider): store the current key with `security " <>
        "add-generic-password -s \"Lemon Secrets\" -a default -w \"$(cat <key file>)\"`, " <>
        "move the key file aside, check `lemon secrets status` reports source keychain, " <>
        "then rotate."

  def describe_error(reason), do: inspect(reason)

  # -- planning ---------------------------------------------------------------

  defp plan(opts) do
    with {:ok, key, source} <- MasterKey.resolve(opts),
         {:ok, provider} <- writable_provider(source, opts),
         :ok <- durable_key_switch(provider, opts),
         {:ok, rows} <- fetch_rows() do
      rows = Enum.map(rows, fn {ref, entry} -> {ref, entry, expired?(entry)} end)
      expired = for {ref, entry, true} <- rows, do: {ref, entry}
      live = for {ref, entry, false} <- rows, do: %{ref: ref, entry: entry, via: via(entry, key)}

      case for(%{ref: ref, via: :error} <- live, do: ref) do
        [] ->
          {:ok,
           %{
             key: key,
             source: source,
             provider: provider,
             opts: opts,
             live: live,
             expired: expired,
             token: token(source, key, rows)
           }}

        failed ->
          {:error, {:undecryptable_secrets, failed |> Enum.sort() |> Enum.map(&ref_map/1)}}
      end
    end
  end

  defp writable_provider(source, opts) do
    provider = opts |> KeyProvider.order() |> Enum.find(&(KeyProvider.name(&1) == source))

    if provider && KeyProvider.supports_put?(provider) do
      {:ok, provider}
    else
      {:error, {:read_only_key_source, source}}
    end
  end

  # A key file is replaced by rename; unless the directory flush is
  # synchronous on this host, a crash after promotion could resurrect the old
  # key with no ciphertext it opens. Refuse before anything is written.
  defp durable_key_switch(provider, opts) do
    if KeyProvider.name(provider) == :file do
      case KeyProvider.File.durable_replace(opts) do
        :ok -> :ok
        {:error, reason} -> {:error, {:key_file_not_durable, safe_reason(reason)}}
      end
    else
      :ok
    end
  end

  defp fetch_rows do
    case Store.fetch_all(Secrets.table()) do
      {:ok, rows} ->
        # Receipt-only tombstones carry historical proof, not encrypted values.
        {:ok, rows |> Enum.reject(fn {_ref, entry} -> LemonCore.Secrets.Receipts.receipt_only?(entry) end) |> Enum.sort_by(&elem(&1, 0))}

      {:error, reason} ->
        {:error, {:store_failed, safe_reason(reason)}}
    end
  end

  defp via(entry, key) do
    case open(entry, key) do
      {:ok, _plaintext, via} -> via
      {:error, _reason} -> :error
    end
  end

  defp token(source, key, rows) do
    refs = Enum.map(rows, fn {ref, entry, expired} -> {ref, revision(entry), expired} end)

    {@token_version, source, fingerprint(key), refs}
    |> :erlang.term_to_binary()
    |> sha256()
  end

  defp fingerprint(key), do: :crypto.mac(:hmac, :sha256, key, @fingerprint_info)

  defp summary(plan) do
    %{
      source: plan.source,
      key_file: key_file(plan),
      count: length(plan.live),
      expired: length(plan.expired),
      resumed: Enum.count(plan.live, &(&1.via == :staged)),
      confirmation_token: plan.token
    }
  end

  defp key_file(%{source: :file, opts: opts}), do: MasterKey.key_file(opts)
  defp key_file(_plan), do: nil

  defp confirm(plan, confirmation) do
    if secure_equal?(plan.token, confirmation),
      do: :ok,
      else: {:error, :confirmation_mismatch}
  end

  # -- execution --------------------------------------------------------------

  defp execute(plan) do
    encoded = MasterKey.generate_encoded_key()
    new_key = Base.decode64!(encoded)

    with :ok <- prune_expired(plan.expired),
         {:ok, staged} <- stage(plan, new_key),
         :ok <- verify_staged(staged, new_key),
         :ok <- persist_staged(staged),
         :ok <- switch_key(plan, encoded, new_key),
         :ok <- converge(plan.key, new_key, @converge_passes) do
      {:ok,
       %{
         source: plan.source,
         key_file: key_file(plan),
         rotated: length(staged),
         pruned: length(plan.expired)
       }}
    end
  end

  defp prune_expired(expired) do
    Enum.reduce_while(expired, :ok, fn {ref, entry}, :ok ->
      case prune_record(ref, entry) do
        :ok -> {:cont, :ok}
        {:error, :mismatch} -> {:halt, {:error, :target_changed}}
        {:error, reason} -> {:halt, {:error, {:store_failed, safe_reason(reason)}}}
      end
    end)
  end

  defp prune_record(ref, entry) do
    if LemonCore.Secrets.Receipts.entries(entry) == [],
      do: Store.compare_and_delete(Secrets.table(), ref, entry),
      else: Store.compare_and_swap(Secrets.table(), ref, entry, Secrets.receipt_only_entry(entry))
  end

  defp stage(plan, new_key) do
    plan.live
    |> Enum.reduce_while({:ok, []}, fn %{ref: ref, entry: entry}, {:ok, acc} ->
      expected = revision(entry)

      change = fn current ->
        if revision(current) == expected,
          do: staged_entry(ref, current, plan.key, new_key),
          else: {:error, :target_changed}
      end

      case swap(ref, entry, change) do
        {:ok, written} ->
          {:cont, {:ok, [{ref, written} | acc]}}

        {:error, _reason} = error ->
          unstage(acc)
          {:halt, error}
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      error -> error
    end
  end

  # The primary fields keep ciphertext the current key opens; for a record left
  # by an interrupted rotation that is its staged copy, which is promoted here.
  defp staged_entry(ref, entry, key, new_key) do
    case open(entry, key) do
      {:ok, plaintext, via} ->
        with {:ok, encrypted} <- Crypto.encrypt(plaintext, new_key) do
          current = if via == :staged, do: staged(entry), else: entry
          staged = Map.new(@cipher_fields, &{&1, Map.fetch!(encrypted, &1)})

          {:ok, entry |> put_cipher(current) |> put_field(:staged, staged)}
        end

      {:error, _reason} ->
        {:error, {:undecryptable_secrets, [ref_map(ref)]}}
    end
  end

  defp verify_staged(staged, new_key) do
    case fetch_rows() do
      {:ok, rows} ->
        current = Map.new(rows)
        expected = Map.new(staged)

        unchanged? =
          Enum.all?(rows, fn {ref, entry} -> Map.has_key?(expected, ref) or expired?(entry) end) and
            Enum.all?(staged, fn {ref, written} ->
              entry = Map.get(current, ref)

              is_map(entry) and revision(entry) == revision(written) and
                match?({:ok, _}, Crypto.decrypt(staged(entry) || %{}, new_key))
            end)

        if unchanged? do
          :ok
        else
          unstage(staged)
          {:error, :target_changed}
        end

      {:error, _reason} = error ->
        unstage(staged)
        error
    end
  end

  # Durability barrier: the key must not move before every staged copy would
  # survive a host crash. The key is untouched here, so dropping them is safe.
  defp persist_staged(staged) do
    case Store.sync() do
      :ok ->
        :ok

      {:error, reason} ->
        unstage(staged)
        {:error, {:store_not_durable, safe_reason(reason)}}
    end
  end

  # Staged copies are never dropped once `put/2` has been attempted: a write
  # that reported failure or timed out may still land, and the staged copies
  # are what keep every record readable if it does. The switch counts only
  # when the provider written to holds the new key and resolution loads it.
  defp switch_key(plan, encoded, new_key) do
    put_result = plan.provider.put(encoded, Keyword.put(plan.opts, :force, true))
    held = MasterKey.fetch_from(plan.provider, plan.opts)

    cond do
      put_result == :ok and held == {:ok, new_key} and loads?(plan.opts, new_key) ->
        :ok

      put_result != :ok and held == {:ok, plan.key} ->
        {:error, {:key_switch_failed, plan.source, put_failure(put_result)}}

      true ->
        {:error, {:key_switch_unverified, plan.source}}
    end
  end

  defp loads?(opts, key), do: match?({:ok, ^key, _source}, MasterKey.resolve(opts))

  defp put_failure({:error, reason}), do: safe_reason(reason)
  defp put_failure(_other), do: :unexpected_result

  # Brings every record to ciphertext under the new key alone. Staged copies
  # are durable (synced before the switch or at the end of an earlier pass)
  # and are promoted; a record only the previous key opens is first staged and
  # synced, and promoted on the next pass. Succeeds only once a pass finds
  # every live record done.
  defp converge(old_key, new_key, passes) do
    with {:ok, rows} <- fetch_rows() do
      outcomes = Enum.map(rows, fn {ref, entry} -> converge_record(ref, entry, old_key, new_key) end)
      pending = Enum.count(outcomes, &(&1 in [:staged, :failed]))

      with :ok <- sync_if(Enum.any?(outcomes, &(&1 in [:changed, :staged]))) do
        cond do
          pending == 0 -> :ok
          passes > 1 -> converge(old_key, new_key, passes - 1)
          true -> {:error, {:promotion_incomplete, pending}}
        end
      end
    end
  end

  defp converge_record(ref, entry, old_key, new_key) do
    if expired?(entry) do
      case prune_record(ref, entry) do
        :ok -> :changed
        {:error, _reason} -> :failed
      end
    else
      case swap(ref, entry, &converged_entry(ref, &1, old_key, new_key)) do
        :skip -> :done
        {:ok, written} -> if staged(written), do: :staged, else: :changed
        {:error, :target_changed} -> :done
        {:error, _reason} -> :failed
      end
    end
  end

  defp converged_entry(ref, entry, old_key, new_key) do
    staged = staged(entry)

    cond do
      opens?(entry, new_key) and is_nil(staged) -> :skip
      opens?(entry, new_key) -> {:ok, drop_staged(entry)}
      is_map(staged) and opens?(staged, new_key) -> {:ok, promoted(entry)}
      true -> staged_entry(ref, entry, old_key, new_key)
    end
  end

  defp sync_if(false), do: :ok

  defp sync_if(true) do
    case Store.sync() do
      :ok -> :ok
      {:error, reason} -> {:error, {:store_failed, safe_reason(reason)}}
    end
  end

  defp opens?(payload, key), do: match?({:ok, _}, Crypto.decrypt(payload, key))

  defp promoted(entry), do: entry |> put_cipher(staged(entry)) |> drop_staged()

  # Best effort: a staged copy left behind is ignored while the primary
  # ciphertext opens, and replaced by the next rotation.
  defp unstage(staged) do
    Enum.each(staged, fn {ref, written} ->
      staged_cipher = cipher(staged(written))

      swap(ref, written, fn current ->
        if cipher(staged(current)) == staged_cipher, do: {:ok, drop_staged(current)}, else: :skip
      end)
    end)
  end

  # Compare-and-swap `change.(entry)` into the store. A mismatch is retried
  # against the fresh record (`change` decides whether it is still the same
  # secret), so a concurrent usage-count update does not abort the step.
  defp swap(ref, entry, change, attempts \\ @swap_attempts) do
    with {:ok, replacement} <- change.(entry) do
      case Store.compare_and_swap(Secrets.table(), ref, entry, replacement) do
        :ok ->
          {:ok, replacement}

        {:error, :mismatch} when attempts > 1 ->
          case Store.fetch(Secrets.table(), ref) do
            {:ok, current} when is_map(current) -> swap(ref, current, change, attempts - 1)
            {:ok, _missing} -> {:error, :target_changed}
            {:error, reason} -> {:error, {:store_failed, safe_reason(reason)}}
          end

        {:error, :mismatch} ->
          {:error, :contended}

        {:error, reason} ->
          {:error, {:store_failed, safe_reason(reason)}}
      end
    end
  end

  # -- records ----------------------------------------------------------------

  defp open(entry, key) do
    case Crypto.decrypt(entry, key) do
      {:ok, plaintext} ->
        {:ok, plaintext, :primary}

      {:error, reason} ->
        with staged when is_map(staged) <- staged(entry),
             {:ok, plaintext} <- Crypto.decrypt(staged, key) do
          {:ok, plaintext, :staged}
        else
          _ -> {:error, reason}
        end
    end
  end

  defp expired?(entry), do: is_map(entry) and Secrets.expired_entry?(entry)

  defp staged(entry) when is_map(entry), do: MapHelpers.get_key(entry, :staged)
  defp staged(_entry), do: nil

  defp revision(entry), do: {cipher(entry), cipher(staged(entry))}

  defp cipher(payload) when is_map(payload),
    do: Enum.map(@cipher_fields, &MapHelpers.get_key(payload, &1))

  defp cipher(_payload), do: nil

  defp put_cipher(entry, payload) do
    Enum.reduce(@cipher_fields, entry, fn field, acc ->
      put_field(acc, field, MapHelpers.get_key(payload, field))
    end)
  end

  defp drop_staged(entry), do: entry |> Map.delete(:staged) |> Map.delete("staged")

  defp put_field(map, key, value) do
    map
    |> Map.put(key, value)
    |> Map.delete(Atom.to_string(key))
  end

  defp ref_map({owner, name}), do: %{owner: owner, name: name}
  defp ref_map(ref), do: %{owner: nil, name: inspect(ref)}

  defp safe_reason(reason) when is_atom(reason), do: reason

  defp safe_reason(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and
              is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp safe_reason(_reason), do: :unknown

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right),
    do: byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
end
