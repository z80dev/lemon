defmodule LemonCore.Secrets.Crypto do
  @moduledoc """
  Cryptographic helpers for encrypted secret storage.

  This module encrypts secret values with AES-256-GCM and derives per-secret
  keys using HKDF-SHA256 from the configured master key and a random salt.
  """

  @version "lemon-secrets-v1"
  @aad @version
  @tag_bytes 16
  @nonce_bytes 12
  @salt_bytes 32
  @key_bytes 32
  @hash_bytes 32

  @type encrypted_secret :: %{
          required(:ciphertext) => String.t(),
          required(:nonce) => String.t(),
          required(:salt) => String.t(),
          required(:version) => String.t()
        }

  @spec version() :: String.t()
  def version, do: @version

  @spec encrypt(String.t(), binary()) :: {:ok, encrypted_secret()} | {:error, atom()}
  def encrypt(plaintext, master_key) when is_binary(plaintext) and is_binary(master_key) do
    with :ok <- validate_master_key(master_key),
         salt <- :crypto.strong_rand_bytes(@salt_bytes),
         nonce <- :crypto.strong_rand_bytes(@nonce_bytes),
         key <- derive_key(master_key, salt),
         {ciphertext, tag} <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             plaintext,
             @aad,
             @tag_bytes,
             true
           ) do
      {:ok,
       %{
         ciphertext: Base.encode64(ciphertext <> tag),
         nonce: Base.encode64(nonce),
         salt: Base.encode64(salt),
         version: @version
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :encrypt_failed}
    end
  rescue
    _ -> {:error, :encrypt_failed}
  end

  def encrypt(_, _), do: {:error, :invalid_plaintext}

  @spec decrypt(map(), binary()) :: {:ok, String.t()} | {:error, atom()}
  def decrypt(payload, master_key) when is_map(payload) and is_binary(master_key) do
    with :ok <- validate_master_key(master_key),
         {:ok, ciphertext_and_tag} <- decode_field(payload, :ciphertext),
         {:ok, nonce} <- decode_field(payload, :nonce),
         {:ok, salt} <- decode_field(payload, :salt),
         {:ok, {ciphertext, tag}} <- split_ciphertext_and_tag(ciphertext_and_tag),
         key <- derive_key(master_key, salt),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             @aad,
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :decrypt_failed}
      _ -> {:error, :decrypt_failed}
    end
  rescue
    _ -> {:error, :decrypt_failed}
  end

  def decrypt(_, _), do: {:error, :invalid_payload}

  defp validate_master_key(master_key) do
    if byte_size(master_key) >= @key_bytes do
      :ok
    else
      {:error, :invalid_master_key}
    end
  end

  defp decode_field(payload, field) do
    value = Map.get(payload, field) || Map.get(payload, Atom.to_string(field))

    cond do
      not is_binary(value) ->
        {:error, :invalid_payload}

      true ->
        case Base.decode64(value) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, :invalid_payload}
        end
    end
  end

  defp split_ciphertext_and_tag(data) when byte_size(data) > @tag_bytes do
    size = byte_size(data) - @tag_bytes
    {:ok, {binary_part(data, 0, size), binary_part(data, size, @tag_bytes)}}
  end

  defp split_ciphertext_and_tag(_), do: {:error, :invalid_payload}

  defp derive_key(master_key, salt) do
    hkdf_sha256(master_key, salt, @version, @key_bytes)
  end

  # HKDF-SHA256 implementation based on RFC 5869.
  defp hkdf_sha256(ikm, salt, info, len) do
    salt = if byte_size(salt) == 0, do: :binary.copy(<<0>>, @hash_bytes), else: salt
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    expand_hkdf(prk, info, len, <<>>, <<>>, 1)
  end

  defp expand_hkdf(_prk, _info, len, output, _prev, _counter) when byte_size(output) >= len do
    binary_part(output, 0, len)
  end

  defp expand_hkdf(prk, info, len, output, prev, counter) do
    next = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<counter>>)
    expand_hkdf(prk, info, len, output <> next, next, counter + 1)
  end
end
