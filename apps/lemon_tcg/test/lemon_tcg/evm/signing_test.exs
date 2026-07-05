defmodule LemonTcg.Evm.SigningTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Evm.{Eip712, Keccak, Rlp, Secp256k1, Transaction}

  describe "Keccak-256" do
    test "matches canonical vectors" do
      assert Keccak.hex256("") ==
               "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

      assert Keccak.hex256("abc") ==
               "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"

      assert Keccak.hex256("The quick brown fox jumps over the lazy dog") ==
               "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15"
    end
  end

  describe "secp256k1 address derivation" do
    test "matches known private-key vectors with EIP-55 checksums" do
      assert Secp256k1.address_hex(<<1::256>>) ==
               "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"

      assert Secp256k1.address_hex(:binary.copy(<<0x46>>, 32)) ==
               "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F"
    end

    test "RFC 6979 signatures are deterministic" do
      digest = Keccak.hash256("determinism")
      key = :binary.copy(<<0x11>>, 32)
      assert Secp256k1.sign(digest, key) == Secp256k1.sign(digest, key)
    end

    test "signatures are low-s normalized (EIP-2)" do
      n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

      for i <- 1..6 do
        sig = Secp256k1.sign(Keccak.hash256("msg#{i}"), :binary.copy(<<i>>, 32))
        assert sig.s <= div(n, 2)
        assert sig.recovery_id in [0, 1]
      end
    end
  end

  describe "RLP" do
    test "encodes canonical examples" do
      assert Rlp.encode("dog") == <<0x83, ?d, ?o, ?g>>
      assert Rlp.encode(["cat", "dog"]) == <<0xC8, 0x83, ?c, ?a, ?t, 0x83, ?d, ?o, ?g>>
      assert Rlp.encode("") == <<0x80>>
      assert Rlp.encode([]) == <<0xC0>>
      assert Rlp.encode(<<0x00>>) == <<0x00>>
      assert Rlp.encode(<<0x0F>>) == <<0x0F>>
      assert Rlp.encode_int(1024) == <<0x04, 0x00>>
      assert Rlp.encode_int(0) == <<>>
    end
  end

  describe "transaction signing" do
    test "legacy EIP-155 matches the Ethereum-book golden vector" do
      priv = Base.decode16!("46" |> String.duplicate(32))
      to = Base.decode16!("3535353535353535353535353535353535353535")

      tx = %{
        chain_id: 1,
        nonce: 9,
        gas_price: 20_000_000_000,
        gas: 21_000,
        to: to,
        value: 1_000_000_000_000_000_000,
        data: <<>>
      }

      {raw, _hash} = Transaction.sign_legacy(tx, priv)

      assert raw ==
               "0xf86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3" <>
                 "a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276" <>
                 "a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83"
    end

    test "EIP-1559 produces a type-2 envelope and a 32-byte hash" do
      priv = :binary.copy(<<0x46>>, 32)

      tx = %{
        chain_id: 137,
        nonce: 3,
        max_priority_fee_per_gas: 30_000_000_000,
        max_fee_per_gas: 100_000_000_000,
        gas: 200_000,
        to: :binary.copy(<<0x11>>, 20),
        value: 5_115_000,
        data: <<0xDE, 0xAD>>
      }

      {raw, hash} = Transaction.sign_eip1559(tx, priv)
      assert String.starts_with?(raw, "0x02")
      assert String.starts_with?(hash, "0x")
      assert byte_size(Base.decode16!(String.replace_prefix(hash, "0x", ""), case: :lower)) == 32
    end
  end

  describe "EIP-712 digest" do
    test "assembles 0x1901 || domain || struct" do
      domain = :binary.copy(<<0xAA>>, 32)
      struct_hash = :binary.copy(<<0xBB>>, 32)
      expected = Keccak.hash256(<<0x19, 0x01>> <> domain <> struct_hash)
      assert Eip712.digest(domain, struct_hash) == expected
    end
  end
end
