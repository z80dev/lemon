defmodule LemonGateway.Telegram.PollerLock do
  @moduledoc false

  # Telegram getUpdates is "at least once" if you have multiple pollers. Running two pollers
  # (e.g. legacy LemonGateway transport + lemon_channels adapter) will double-submit inbound
  # messages and produce duplicate replies.
  #
  # We use a :global lock so only one poller per (account_id, token) can run in a BEAM cluster.

  @spec acquire(term(), term()) :: :ok | {:error, :locked}
  def acquire(account_id, token) do
    case :global.register_name(lock_name(account_id, token), self()) do
      :yes -> :ok
      :no -> {:error, :locked}
    end
  end

  @spec release(term(), term()) :: :ok
  def release(account_id, token) do
    _ = :global.unregister_name(lock_name(account_id, token))
    :ok
  rescue
    _ -> :ok
  end

  defp lock_name(account_id, token) do
    {:lemon, :telegram_poller, normalize_account_id(account_id), token_fingerprint(token)}
  end

  defp normalize_account_id(nil), do: "default"
  defp normalize_account_id(account_id), do: to_string(account_id)

  defp token_fingerprint(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp token_fingerprint(_), do: "no_token"
end
