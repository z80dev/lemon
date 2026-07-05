defmodule LemonTcg.Wallet.EvmKeypair do
  @moduledoc """
  Local EVM keypair wallet (secp256k1, pure Elixir signing).

  Key material, in priority order:

    * `config[:private_key]` — 32-byte binary, or `"0x…"` / hex string
    * `EVM_PRIVATE_KEY` — hex (with or without `0x`)

  Signs EIP-1559 (default) or legacy transactions, and arbitrary 32-byte
  digests for EIP-712 orders (65-byte `r||s||v` with `v = recovery + 27`).
  Keep this a hot wallet with a small balance.
  """

  @behaviour LemonTcg.Wallet

  alias LemonTcg.Evm.{Secp256k1, Transaction}

  @impl true
  def address(config) do
    with {:ok, key} <- private_key(config), do: {:ok, Secp256k1.address_hex(key)}
  end

  @impl true
  def sign_evm_transaction(tx, config) do
    with {:ok, key} <- private_key(config) do
      {raw, _hash} =
        case Map.get(tx, :type, :eip1559) do
          :legacy -> Transaction.sign_legacy(tx, key)
          _ -> Transaction.sign_eip1559(tx, key)
        end

      {:ok, raw}
    end
  end

  @impl true
  def sign_hash(<<_::binary-size(32)>> = hash, config) do
    with {:ok, key} <- private_key(config) do
      %{r: r, s: s, recovery_id: rec} = Secp256k1.sign(hash, key)
      {:ok, "0x" <> Base.encode16(<<r::256, s::256, rec + 27>>, case: :lower)}
    end
  end

  def sign_hash(_hash, _config), do: {:error, :invalid_digest}

  defp private_key(config) do
    cond do
      match?(<<_::binary-size(32)>>, config[:private_key]) ->
        {:ok, config[:private_key]}

      is_binary(config[:private_key]) ->
        decode_hex(config[:private_key])

      encoded = System.get_env("EVM_PRIVATE_KEY") ->
        decode_hex(encoded)

      true ->
        {:error, :no_evm_private_key}
    end
  end

  defp decode_hex(hex) do
    cleaned = hex |> String.trim() |> String.replace_prefix("0x", "")

    case Base.decode16(cleaned, case: :mixed) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      {:ok, _wrong_size} -> {:error, :invalid_private_key_length}
      :error -> {:error, :invalid_private_key_hex}
    end
  end
end
