defmodule LemonTcg.Wallet do
  @moduledoc """
  Behaviour for transaction signing across chains.

  A wallet holds keys and signs; it never chooses what to sign — that is
  the venue's job, and every order has already passed `LemonTcg.Risk` by
  the time a wallet sees it. Configure a desk with
  `wallet: {module, config}`; the default `Unconfigured` wallet refuses
  everything, so live venues fail closed until keys are provided
  deliberately.

  Solana wallets implement `pubkey/1` + `sign_transaction/2`; EVM wallets
  implement `address/1` + `sign_evm_transaction/2` + `sign_hash/2`. All
  callbacks are optional so a wallet implements only its chain's family.
  """

  @type config :: keyword()

  @doc "Base58 Solana public key."
  @callback pubkey(config()) :: {:ok, String.t()} | {:error, term()}

  @doc "Sign a base64-encoded serialized Solana transaction, returning base64."
  @callback sign_transaction(base64_tx :: String.t(), config()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Checksummed EVM address (`0x…`)."
  @callback address(config()) :: {:ok, String.t()} | {:error, term()}

  @doc "Sign an EVM transaction map, returning `{:ok, raw_tx_hex}`."
  @callback sign_evm_transaction(tx :: map(), config()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Sign a 32-byte digest, returning a 65-byte `0x` signature (EIP-712 orders)."
  @callback sign_hash(hash :: binary(), config()) :: {:ok, String.t()} | {:error, term()}

  @optional_callbacks pubkey: 1,
                      sign_transaction: 2,
                      address: 1,
                      sign_evm_transaction: 2,
                      sign_hash: 2

  @doc "Normalize a wallet option into `{module, config}`."
  @spec resolve(module() | {module(), config()} | nil) :: {module(), config()}
  def resolve(nil), do: {LemonTcg.Wallet.Unconfigured, []}
  def resolve({module, config}) when is_atom(module) and is_list(config), do: {module, config}
  def resolve(module) when is_atom(module), do: {module, []}
end
