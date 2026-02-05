defmodule LemonGateway.Telegram.OffsetStore do
  @moduledoc false

  @table :telegram_offsets

  @spec get(term(), term()) :: integer() | nil
  def get(account_id, token) do
    if store_available?() do
      key = key(account_id, token)

      case LemonGateway.Store.get(@table, key) do
        offset when is_integer(offset) -> offset
        _ -> nil
      end
    else
      nil
    end
  end

  @spec put(term(), term(), integer()) :: :ok
  def put(account_id, token, offset) when is_integer(offset) do
    if store_available?() do
      key = key(account_id, token)
      _ = LemonGateway.Store.put(@table, key, offset)
    end

    :ok
  end

  defp store_available? do
    Code.ensure_loaded?(LemonGateway.Store) and
      function_exported?(LemonGateway.Store, :get, 2) and
      is_pid(Process.whereis(LemonGateway.Store))
  end

  defp key(account_id, token) do
    {normalize_account_id(account_id), token_fingerprint(token)}
  end

  defp normalize_account_id(nil), do: "default"
  defp normalize_account_id(account_id), do: to_string(account_id)

  defp token_fingerprint(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp token_fingerprint(_), do: "no_token"
end
