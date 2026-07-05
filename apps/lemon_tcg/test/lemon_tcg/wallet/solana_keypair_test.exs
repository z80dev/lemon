defmodule LemonTcg.Wallet.SolanaKeypairTest do
  # Mutates SOLANA_SECRET_KEY / SOLANA_KEYPAIR_FILE env vars — not async.
  use ExUnit.Case, async: false

  alias LemonTcg.Solana.{Base58, Tx}
  alias LemonTcg.Wallet
  alias LemonTcg.Wallet.SolanaKeypair

  defp keypair do
    {pub, seed} = :crypto.generate_key(:eddsa, :ed25519)
    {pub, seed <> pub}
  end

  defp single_signer_tx(pub) do
    message = <<1, 0, 1>> <> Tx.encode_shortvec(1) <> pub <> :crypto.strong_rand_bytes(40)
    Base.encode64(Tx.encode_shortvec(1) <> :binary.copy(<<0>>, 64) <> message)
  end

  test "resolve normalizes wallet option forms" do
    assert {SolanaKeypair, []} = Wallet.resolve(SolanaKeypair)
    assert {SolanaKeypair, [secret_key: "x"]} = Wallet.resolve({SolanaKeypair, [secret_key: "x"]})
    assert {LemonTcg.Wallet.Unconfigured, []} = Wallet.resolve(nil)
  end

  test "pubkey and signing from an in-memory secret key" do
    {pub, secret} = keypair()
    config = [secret_key: secret]

    assert {:ok, encoded_pub} = SolanaKeypair.pubkey(config)
    assert {:ok, ^pub} = Base58.decode(encoded_pub)

    assert {:ok, signed_b64} = SolanaKeypair.sign_transaction(single_signer_tx(pub), config)
    {:ok, signed} = Base.decode64(signed_b64)
    {:ok, 1, [sig], message} = Tx.split(signed)
    assert :crypto.verify(:eddsa, :none, message, sig, [pub, :ed25519])
  end

  test "loads a solana-keygen JSON keypair file" do
    {pub, secret} = keypair()
    path = Path.join(System.tmp_dir!(), "kp_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(:erlang.binary_to_list(secret)))
    on_exit(fn -> File.rm(path) end)

    assert {:ok, encoded_pub} = SolanaKeypair.pubkey(keypair_path: path)
    assert {:ok, ^pub} = Base58.decode(encoded_pub)
  end

  test "reads a base58 secret from SOLANA_SECRET_KEY" do
    {pub, secret} = keypair()
    System.put_env("SOLANA_SECRET_KEY", Base58.encode(secret))
    on_exit(fn -> System.delete_env("SOLANA_SECRET_KEY") end)

    assert {:ok, encoded_pub} = SolanaKeypair.pubkey([])
    assert {:ok, ^pub} = Base58.decode(encoded_pub)
  end

  test "clean errors for missing and malformed key material" do
    System.delete_env("SOLANA_SECRET_KEY")
    System.delete_env("SOLANA_KEYPAIR_FILE")
    assert {:error, :no_solana_keypair} = SolanaKeypair.pubkey([])

    assert {:error, {:keypair_file_unreadable, _, :enoent}} =
             SolanaKeypair.pubkey(keypair_path: "/nonexistent/does/not/exist.json")

    assert {:error, :invalid_base64_transaction} =
             SolanaKeypair.sign_transaction("not base64!!", secret_key: :binary.copy(<<0>>, 64))
  end

  test "unconfigured wallet refuses to sign" do
    assert {:error, :wallet_not_configured} = LemonTcg.Wallet.Unconfigured.pubkey([])

    assert {:error, :wallet_not_configured} =
             LemonTcg.Wallet.Unconfigured.sign_transaction("x", [])
  end
end
