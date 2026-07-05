defmodule LemonTcg.Wallet.Unconfigured do
  @moduledoc """
  Default wallet: refuses to sign anything.

  Live venues (Solana or EVM) fail closed with `:wallet_not_configured`
  until the desk is deliberately given keys.
  """

  @behaviour LemonTcg.Wallet

  @impl true
  def pubkey(_config), do: {:error, :wallet_not_configured}

  @impl true
  def sign_transaction(_base64_tx, _config), do: {:error, :wallet_not_configured}

  @impl true
  def address(_config), do: {:error, :wallet_not_configured}

  @impl true
  def sign_evm_transaction(_tx, _config), do: {:error, :wallet_not_configured}

  @impl true
  def sign_hash(_hash, _config), do: {:error, :wallet_not_configured}
end
