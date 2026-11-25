defmodule LemonCore.Secrets.Record do
  @moduledoc false

  alias LemonCore.{Clock, MapHelpers, Store}
  alias LemonCore.Secrets.Crypto

  @table :secrets_v1
  @verifier_key :key_check

  def table, do: @table
  def verifier_key, do: @verifier_key

  def fetch_rows(server \\ Store) do
    with {:ok, rows} <- Store.fetch_all(server, @table) do
      {:ok, Enum.reject(rows, fn {key, _entry} -> key == @verifier_key end)}
    end
  end

  def value?(entry) when is_map(entry), do: is_binary(MapHelpers.get_key(entry, :ciphertext))
  def value?(_), do: false

  def expired?(entry) do
    expires_at = MapHelpers.get_key(entry, :expires_at)
    is_integer(expires_at) and expires_at > 0 and expires_at <= Clock.now_ms()
  end

  def decrypt(entry, master_key) do
    case open(entry, master_key) do
      {:ok, plaintext, _via} -> {:ok, plaintext}
      {:error, _reason} = error -> error
    end
  end

  # A record remains usable on either side of a key publication, including
  # when rotation was interrupted between staging and promoting ciphertext.
  def open(entry, key) do
    case Crypto.decrypt(entry, key) do
      {:ok, plaintext} ->
        {:ok, plaintext, :primary}

      {:error, reason} ->
        with staged when is_map(staged) <- staged(entry),
             {:ok, plaintext} <- Crypto.decrypt(staged, key) do
          {:ok, plaintext, :staged}
        else
          _ -> {:error, reason}
        end
    end
  end

  def staged(entry) when is_map(entry), do: MapHelpers.get_key(entry, :staged)
  def staged(_entry), do: nil
end
