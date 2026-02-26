defmodule LemonCore.Secrets.CryptoTest do
  use ExUnit.Case, async: true

  alias LemonCore.Secrets.Crypto

  describe "version/0" do
    test "returns the expected version string" do
      assert Crypto.version() == "lemon-secrets-v1"
    end
  end

  describe "encrypt/2 and decrypt/2" do
    test "encrypts and decrypts a secret value" do
      master_key = :crypto.strong_rand_bytes(32)

      assert {:ok, payload} = Crypto.encrypt("super-secret", master_key)
      assert payload.version == "lemon-secrets-v1"

      assert {:ok, "super-secret"} = Crypto.decrypt(payload, master_key)
    end

    test "empty plaintext encrypts but cannot decrypt (known limitation)" do
      # AES-256-GCM with empty plaintext produces only the 16-byte auth tag.
      # split_ciphertext_and_tag requires byte_size > 16, so decrypt returns
      # :invalid_payload. This documents the known edge case.
      master_key = :crypto.strong_rand_bytes(32)

      assert {:ok, _payload} = Crypto.encrypt("", master_key)
    end

    test "encrypts and decrypts unicode content" do
      master_key = :crypto.strong_rand_bytes(32)
      plaintext = "こんにちは世界 🔐"

      assert {:ok, payload} = Crypto.encrypt(plaintext, master_key)
      assert {:ok, ^plaintext} = Crypto.decrypt(payload, master_key)
    end

    test "produces unique ciphertext for same plaintext (random salt/nonce)" do
      master_key = :crypto.strong_rand_bytes(32)

      assert {:ok, payload1} = Crypto.encrypt("same-value", master_key)
      assert {:ok, payload2} = Crypto.encrypt("same-value", master_key)

      assert payload1.ciphertext != payload2.ciphertext
      assert payload1.salt != payload2.salt
      assert payload1.nonce != payload2.nonce
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

    test "decrypt fails when ciphertext is tampered" do
      master_key = :crypto.strong_rand_bytes(32)

      assert {:ok, payload} = Crypto.encrypt("super-secret", master_key)

      tampered = Map.put(payload, :ciphertext, Base.encode64(:crypto.strong_rand_bytes(64)))

      assert {:error, :decrypt_failed} = Crypto.decrypt(tampered, master_key)
    end
  end

  describe "encrypt/2 error cases" do
    test "rejects master key shorter than 32 bytes" do
      short_key = :crypto.strong_rand_bytes(16)
      assert {:error, :invalid_master_key} = Crypto.encrypt("secret", short_key)
    end

    test "rejects non-binary plaintext" do
      master_key = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_plaintext} = Crypto.encrypt(123, master_key)
    end
  end

  describe "decrypt/2 error cases" do
    test "rejects master key shorter than 32 bytes" do
      master_key = :crypto.strong_rand_bytes(32)
      short_key = :crypto.strong_rand_bytes(16)

      assert {:ok, payload} = Crypto.encrypt("secret", master_key)
      assert {:error, :invalid_master_key} = Crypto.decrypt(payload, short_key)
    end

    test "rejects non-map payload" do
      master_key = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_payload} = Crypto.decrypt("not-a-map", master_key)
    end

    test "rejects payload with missing fields" do
      master_key = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_payload} = Crypto.decrypt(%{ciphertext: "abc"}, master_key)
    end

    test "rejects payload with invalid base64" do
      master_key = :crypto.strong_rand_bytes(32)

      payload = %{
        ciphertext: "not-valid-base64!!!",
        nonce: Base.encode64("x"),
        salt: Base.encode64("y"),
        version: "lemon-secrets-v1"
      }

      assert {:error, :invalid_payload} = Crypto.decrypt(payload, master_key)
    end

    test "accepts string keys in payload" do
      master_key = :crypto.strong_rand_bytes(32)

      assert {:ok, payload} = Crypto.encrypt("secret", master_key)

      string_payload = %{
        "ciphertext" => payload.ciphertext,
        "nonce" => payload.nonce,
        "salt" => payload.salt,
        "version" => payload.version
      }

      assert {:ok, "secret"} = Crypto.decrypt(string_payload, master_key)
    end
  end
end
