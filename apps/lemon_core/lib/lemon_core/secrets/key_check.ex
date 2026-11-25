defmodule LemonCore.Secrets.KeyCheck do
  @moduledoc """
  Durable record of which master key the encrypted secrets store belongs to.

  The verifier is a reserved row (key `:key_check`, never an `{owner, name}`
  pair) in the secrets table itself, so it travels with the records in every
  copy or backup of the store. Secret deletion and expiry never remove it, and
  every scan of secrets skips it (`reserved?/1`):

      %{version: 1, mac: hmac(key), next: nil | hmac(new_key)}

  `mac` is HMAC-SHA256 of a fixed label keyed by the master key; it identifies
  a key without revealing it.

  ## Writes

  `Secrets.set/3`, `set_if_revision/4` and `restore/3` call `ensure/3` under
  `LemonCore.Secrets.Lock` after resolving the key:

    * verifier present, no rotation pending — the key must match, otherwise
      `{:error, :master_key_mismatch}`;
    * rotation pending (`next` set) — `{:error, :key_rotation_incomplete}`:
      records may be readable under two keys, and a write under either would
      leave no single key that opens the whole store. A new rotation is
      admitted only once the provider holds the pending new key; otherwise
      `KeyRotation.recover/2` (`--resume` / `--abandon`) settles it first;
    * no verifier (an empty store, or one written before verifiers existed) —
      legacy migration: every live value record must open with the key (a
      store holding only receipt tombstones has nothing to check), then the
      verifier is written durably. A key that opens only some records is
      refused with `:master_key_mismatch`.

  ## Rotation

  the rotation command checks the verifier in its plan, records
  `next` durably before switching keys (`begin_rotation/2`), and commits the
  new key once the switch is verified, or the previous one when the provider
  provably never attempted the write (`commit/1`). Any other outcome leaves
  `next` set, and a rotation started under the previous key is refused with
  `:key_rotation_unresolved` because the earlier write may still land.
  """

  alias LemonCore.Secrets.Record
  alias LemonCore.Store

  @row Record.verifier_key()
  @table Record.table()
  @label "lemon-secrets-key-check-v1"

  @type verifier :: %{version: 1, mac: binary(), next: binary() | nil}

  @spec mac(binary()) :: binary()
  def mac(key), do: :crypto.mac(:hmac, :sha256, key, @label)

  @spec fetch(Store.server()) :: {:ok, verifier() | nil} | {:error, :secret_store_failed}
  def fetch(server \\ Store) do
    case Store.fetch(server, @table, @row) do
      {:ok, %{mac: mac} = verifier} when is_binary(mac) -> {:ok, verifier}
      {:ok, nil} -> {:ok, nil}
      _ -> {:error, :secret_store_failed}
    end
  end

  @doc "Admits a secret write under `key`; see the module docs."
  @spec ensure(Store.server(), [{term(), term()}], binary()) :: :ok | {:error, atom()}
  def ensure(server, rows, key) do
    case fetch(server) do
      {:ok, %{next: next}} when is_binary(next) -> {:error, :key_rotation_incomplete}
      {:ok, %{mac: mac}} -> if same?(mac, mac(key)), do: :ok, else: mismatch()
      {:ok, nil} -> migrate(server, rows, key)
      error -> error
    end
  end

  @doc """
  Whether `key` is the store's key: `true`/`false` from the verifier (either
  side of a pending rotation counts), `:unknown` when there is none.
  """
  @spec matches?(Store.server(), binary()) :: boolean() | :unknown
  def matches?(server, key) do
    case fetch(server) do
      {:ok, nil} -> :unknown
      {:ok, verifier} -> accepts?(verifier, key)
      _ -> :unknown
    end
  end

  @doc """
  Rotation admission. Without a pending rotation the resolved key must be the
  store's key. With one, only the pending *new* key is admitted (its
  publication has landed); the previous key means that publication is still
  unresolved — a delayed write may yet land — so no new generation may start
  (`:key_rotation_unresolved`) until `KeyRotation.recover/2` settles it.
  """
  @spec check_rotation(binary()) :: :ok | {:error, term()}
  def check_rotation(key) do
    case fetch(Store) do
      {:ok, nil} -> :ok
      {:ok, verifier} -> admit(side(verifier, key))
      error -> error
    end
  end

  defp admit(:current), do: :ok
  defp admit(:next), do: :ok
  defp admit(:unresolved), do: {:error, :key_rotation_unresolved}
  defp admit(:neither), do: mismatch()

  @doc """
  Which side of the verifier `key` is: `:current` (no rotation pending),
  `:unresolved` (the previous key while a rotation is pending), `:next` (the
  pending new key) or `:neither`.
  """
  @spec side(verifier(), binary()) :: :current | :unresolved | :next | :neither
  def side(%{mac: mac} = verifier, key) do
    candidate = mac(key)
    next = verifier[:next]

    cond do
      is_binary(next) and same?(next, candidate) -> :next
      same?(mac, candidate) and is_binary(next) -> :unresolved
      same?(mac, candidate) -> :current
      true -> :neither
    end
  end

  @doc "Durably records that the store is moving from `key` to `new_key`."
  @spec begin_rotation(binary(), binary()) :: :ok | {:error, term()}
  def begin_rotation(key, new_key), do: put(%{version: 1, mac: mac(key), next: mac(new_key)})

  @doc "Durably records `key` as the store's only key."
  @spec commit(binary()) :: :ok | {:error, term()}
  def commit(key), do: put(%{version: 1, mac: mac(key), next: nil})

  defp put(verifier) do
    case Store.put(Store, @table, @row, verifier, durable: true) do
      :ok -> :ok
      {:error, reason} -> {:error, {:store_failed, reason}}
    end
  end

  defp migrate(server, rows, key) do
    values =
      for {_ref, entry} <- rows,
          is_map(entry),
          Record.value?(entry),
          not Record.expired?(entry),
          do: entry

    if Enum.all?(values, &match?({:ok, _}, Record.decrypt(&1, key))) do
      # Same durability as the secret write it precedes (`Secrets` persists
      # records with ordinary writes, which every backend supports).
      case Store.put(server, @table, @row, %{version: 1, mac: mac(key), next: nil}) do
        :ok -> :ok
        {:error, _} -> {:error, :secret_store_failed}
      end
    else
      mismatch()
    end
  end

  defp accepts?(%{mac: mac} = verifier, key) do
    candidate = mac(key)
    same?(mac, candidate) or (is_binary(verifier[:next]) and same?(verifier.next, candidate))
  end

  defp same?(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp same?(_a, _b), do: false

  defp mismatch, do: {:error, :master_key_mismatch}
end
