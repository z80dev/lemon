defmodule LemonCore.Secrets.CryptoTest do
  use ExUnit.Case, async: true

  alias LemonCore.Secrets.Crypto

  test "encrypts and decrypts a secret value" do
    master_key = :crypto.strong_rand_bytes(32)

    assert {:ok, payload} = Crypto.encrypt("super-secret", master_key)
    assert payload.version == "lemon-secrets-v1"

    assert {:ok, "super-secret"} = Crypto.decrypt(payload, master_key)
  end

  test "decrypt fails with wrong master key" do
    master_key = :crypto.strong_rand_bytes(32)
    wrong_key = :crypto.strong_rand_bytes(32)

    assert {:ok, payload} = Crypto.encrypt("super-secret", master_key)
    assert {:error, :decrypt_failed} = Crypto.decrypt(payload, wrong_key)
  end

  test "decrypt fails when payload salt is tampered" do
    master_key = :crypto.strong_rand_bytes(32)

    assert {:ok, payload} = Crypto.encrypt("super-secret", master_key)

    tampered = Map.put(payload, :salt, Base.encode64(:crypto.strong_rand_bytes(32)))

    assert {:error, :decrypt_failed} = Crypto.decrypt(tampered, master_key)
  end
end
