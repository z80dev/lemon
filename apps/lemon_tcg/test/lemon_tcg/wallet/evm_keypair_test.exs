defmodule LemonTcg.Wallet.EvmKeypairTest do
  # Mutates EVM_PRIVATE_KEY env var — not async.
  use ExUnit.Case, async: false

  alias LemonTcg.Wallet
  alias LemonTcg.Wallet.EvmKeypair

  @priv :binary.copy(<<0x46>>, 32)
  @addr "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F"

  test "address from a raw binary key" do
    assert {:ok, @addr} = EvmKeypair.address(private_key: @priv)
  end

  test "address from a 0x-prefixed hex key" do
    hex = "0x" <> String.duplicate("46", 32)
    assert {:ok, @addr} = EvmKeypair.address(private_key: hex)
  end

  test "reads EVM_PRIVATE_KEY from the environment" do
    System.put_env("EVM_PRIVATE_KEY", String.duplicate("46", 32))
    on_exit(fn -> System.delete_env("EVM_PRIVATE_KEY") end)

    assert {:ok, @addr} = EvmKeypair.address([])
  end

  test "signs an EIP-1559 transaction into a type-2 envelope" do
    tx = %{chain_id: 137, nonce: 0, gas: 21_000, to: :binary.copy(<<0x11>>, 20), value: 1}
    assert {:ok, "0x02" <> _} = EvmKeypair.sign_evm_transaction(tx, private_key: @priv)
  end

  test "signs a 32-byte digest into a 65-byte recoverable signature" do
    assert {:ok, "0x" <> hex} = EvmKeypair.sign_hash(:binary.copy(<<0x9>>, 32), private_key: @priv)
    assert byte_size(Base.decode16!(hex, case: :lower)) == 65
    v = hex |> Base.decode16!(case: :lower) |> :binary.last()
    assert v in [27, 28]
  end

  test "clean errors for missing and malformed keys" do
    System.delete_env("EVM_PRIVATE_KEY")
    assert {:error, :no_evm_private_key} = EvmKeypair.address([])
    assert {:error, :invalid_private_key_hex} = EvmKeypair.address(private_key: "0xZZZZ")

    assert {:error, :invalid_private_key_length} =
             EvmKeypair.address(private_key: "0x1234")
  end

  test "unconfigured wallet refuses all signing" do
    assert {:error, :wallet_not_configured} = Wallet.Unconfigured.address([])
    assert {:error, :wallet_not_configured} = Wallet.Unconfigured.sign_evm_transaction(%{}, [])
    assert {:error, :wallet_not_configured} = Wallet.Unconfigured.sign_hash(<<0::256>>, [])
  end
end
