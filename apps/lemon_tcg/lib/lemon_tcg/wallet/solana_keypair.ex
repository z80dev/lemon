defmodule LemonTcg.Wallet.SolanaKeypair do
  @moduledoc """
  Local Solana keypair wallet (ed25519, pure Elixir signing).

  Key material, in priority order:

    * `config[:secret_key]` — 64-byte binary (`seed ++ pubkey`)
    * `config[:keypair_path]` / `SOLANA_KEYPAIR_FILE` — a
      `solana-keygen` JSON file (array of 64 byte values)
    * `SOLANA_SECRET_KEY` — base58 of the 64-byte secret

  Signing inserts our signature into the transaction envelope's slot for
  this pubkey (see `LemonTcg.Solana.Tx`), preserving any co-signatures
  the venue already applied. Keep this wallet's balance small — it is a
  hot wallet by definition.
  """

  @behaviour LemonTcg.Wallet

  alias LemonTcg.Solana.{Base58, Tx}

  @impl true
  def pubkey(config) do
    with {:ok, <<_seed::binary-size(32), pubkey::binary-size(32)>>} <- secret_key(config) do
      {:ok, Base58.encode(pubkey)}
    end
  end

  @impl true
  def sign_transaction(base64_tx, config) do
    with {:ok, secret} <- secret_key(config),
         {:ok, tx_bytes} <- decode64(base64_tx),
         {:ok, signed} <- Tx.sign(tx_bytes, secret) do
      {:ok, Base.encode64(signed)}
    end
  end

  defp decode64(base64) do
    case Base.decode64(base64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_base64_transaction}
    end
  end

  defp secret_key(config) do
    cond do
      is_binary(config[:secret_key]) and byte_size(config[:secret_key]) == 64 ->
        {:ok, config[:secret_key]}

      path = config[:keypair_path] || System.get_env("SOLANA_KEYPAIR_FILE") ->
        read_keypair_file(path)

      encoded = System.get_env("SOLANA_SECRET_KEY") ->
        decode_base58_secret(encoded)

      true ->
        {:error, :no_solana_keypair}
    end
  end

  defp read_keypair_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, bytes} when is_list(bytes) <- Jason.decode(content),
         64 <- length(bytes) do
      {:ok, :erlang.list_to_binary(bytes)}
    else
      {:error, %Jason.DecodeError{}} -> {:error, {:invalid_keypair_file, path}}
      {:error, reason} -> {:error, {:keypair_file_unreadable, path, reason}}
      _ -> {:error, {:invalid_keypair_file, path}}
    end
  end

  defp decode_base58_secret(encoded) do
    case Base58.decode(encoded) do
      {:ok, secret} when byte_size(secret) == 64 -> {:ok, secret}
      _ -> {:error, :invalid_base58_secret}
    end
  end
end
