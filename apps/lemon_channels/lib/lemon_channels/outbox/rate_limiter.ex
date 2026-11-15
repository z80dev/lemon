defmodule LemonChannels.Outbox.RateLimiter do
  @moduledoc """
  Per-channel/account token buckets in ETS.

  The process owns the table, not the send path. Compare-and-replace makes
  consumption atomic across callers; checks refill without consuming a token.
  The existing caller policy is 30 messages/second with a five-message burst.
  """

  use GenServer

  @default_rate 30
  @default_burst 5
  @table :lemon_channels_outbox_rate_limits

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Check without consuming a token."
  @spec check(binary(), binary()) :: :ok | {:rate_limited, non_neg_integer()}
  def check(channel_id, account_id), do: access({channel_id, account_id}, :check)

  @doc "Atomically check and consume one token."
  @spec consume(binary(), binary()) :: :ok | {:rate_limited, non_neg_integer()}
  def consume(channel_id, account_id), do: access({channel_id, account_id}, :consume)

  @doc "Record a send, without allowing the bucket to go negative."
  @spec record(binary(), binary()) :: :ok
  def record(channel_id, account_id) do
    _ = consume(channel_id, account_id)
    :ok
  end

  @spec status(binary(), binary()) :: map()
  def status(channel_id, account_id), do: access({channel_id, account_id}, :status)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  defp access(key, operation) do
    if Process.whereis(__MODULE__) do
      update_bucket(key, operation)
    else
      unavailable(operation)
    end
  rescue
    ArgumentError -> unavailable(operation)
  end

  defp update_bucket(key, operation) do
    now = System.monotonic_time(:millisecond)
    _ = :ets.insert_new(@table, {key, @default_burst, now})
    [{^key, previous_tokens, previous_refill} = previous] = :ets.lookup(@table, key)

    tokens =
      min(@default_burst, previous_tokens + max(now - previous_refill, 0) * @default_rate / 1000)

    allowed? = tokens >= 1
    next_tokens = if operation == :consume and allowed?, do: tokens - 1, else: tokens
    replacement = {key, next_tokens, max(now, previous_refill)}

    match_spec = [
      {{key, :"$1", :"$2"}, [{:"=:=", :"$_", {:const, previous}}], [{:const, replacement}]}
    ]

    if :ets.select_replace(@table, match_spec) == 1 do
      case operation do
        :status -> %{tokens: tokens, rate: @default_rate, burst: @default_burst}
        _ when allowed? -> :ok
        _ -> {:rate_limited, round(1000 / @default_rate)}
      end
    else
      update_bucket(key, operation)
    end
  end

  defp unavailable(:status), do: exit(:rate_limiter_unavailable)
  defp unavailable(_operation), do: {:rate_limited, 1_000}
end
