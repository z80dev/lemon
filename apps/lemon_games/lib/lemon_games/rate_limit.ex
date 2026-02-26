defmodule LemonGames.RateLimit do
  @moduledoc """
  Request and move submission rate limiting for the games API.

  Uses ETS-based sliding window counters.
  """

  @table :game_rate_limits

  @read_limit_per_min 60
  @move_limit_per_min 20
  @move_burst_per_5s 4

  @spec check_read(String.t()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check_read(token_hash) do
    check_window({:read, token_hash}, 60_000, @read_limit_per_min)
  end

  @spec check_move(String.t(), String.t()) :: :ok | {:error, :rate_limited, non_neg_integer()}
  def check_move(token_hash, match_id) do
    with :ok <- check_window({:move, token_hash}, 60_000, @move_limit_per_min),
         :ok <- check_window({:move_burst, token_hash, match_id}, 5_000, @move_burst_per_5s) do
      :ok
    end
  end

  defp check_window(key, window_ms, limit) do
    now = System.system_time(:millisecond)
    window_start = now - window_ms
    full_key = {:rate, key}

    entries =
      case LemonCore.Store.get(@table, full_key) do
        nil -> []
        list -> list
      end

    # Prune expired entries
    active = Enum.filter(entries, fn ts -> ts > window_start end)

    if length(active) >= limit do
      oldest = Enum.min(active, fn -> now end)
      retry_after = oldest + window_ms - now
      {:error, :rate_limited, max(retry_after, 0)}
    else
      updated = [now | active]
      LemonCore.Store.put(@table, full_key, updated)
      :ok
    end
  end
end
