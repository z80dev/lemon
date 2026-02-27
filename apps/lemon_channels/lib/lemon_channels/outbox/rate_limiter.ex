defmodule LemonChannels.Outbox.RateLimiter do
  @moduledoc """
  Rate limiter for outbound message delivery.

  Enforces per-channel rate limits to avoid API throttling.
  """

  use GenServer

  require Logger

  @default_rate 30  # messages per second
  @default_burst 5  # burst allowance
  @call_timeout_ms 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a message can be sent (non-consuming check for initial queue decision).

  Returns `:ok` if allowed, `{:rate_limited, wait_ms}` if rate limited.
  This does NOT consume a token - use `consume/2` for that.
  """
  @spec check(channel_id :: binary(), account_id :: binary()) :: :ok | {:rate_limited, non_neg_integer()}
  def check(channel_id, account_id) do
    GenServer.call(__MODULE__, {:check, channel_id, account_id}, @call_timeout_ms)
  catch
    :exit, _reason ->
      Logger.warning("RateLimiter.check timed out channel=#{channel_id} account=#{account_id}")
      :ok
  end

  @doc """
  Atomically check and consume a rate limit token.

  Returns `:ok` if token was consumed, `{:rate_limited, wait_ms}` if rate limited.
  This is the primary function to use when actually sending a message.
  """
  @spec consume(channel_id :: binary(), account_id :: binary()) :: :ok | {:rate_limited, non_neg_integer()}
  def consume(channel_id, account_id) do
    GenServer.call(__MODULE__, {:consume, channel_id, account_id}, @call_timeout_ms)
  catch
    :exit, _reason ->
      Logger.warning("RateLimiter.consume timed out channel=#{channel_id} account=#{account_id}")
      :ok
  end

  @doc """
  Record that a message was sent (decrements token count).
  """
  @spec record(channel_id :: binary(), account_id :: binary()) :: :ok
  def record(channel_id, account_id) do
    GenServer.cast(__MODULE__, {:record, channel_id, account_id})
  end

  @doc """
  Get the current rate limit status for a channel/account.
  """
  @spec status(channel_id :: binary(), account_id :: binary()) :: map()
  def status(channel_id, account_id) do
    GenServer.call(__MODULE__, {:status, channel_id, account_id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{buckets: %{}}}
  end

  @impl true
  def handle_call({:check, channel_id, account_id}, _from, state) do
    key = {channel_id, account_id}
    now = System.monotonic_time(:millisecond)

    bucket = Map.get(state.buckets, key, new_bucket(now))
    bucket = refill_bucket(bucket, now)

    if bucket.tokens >= 1 do
      # Just checking, don't consume - update bucket state for accurate timing
      buckets = Map.put(state.buckets, key, bucket)
      {:reply, :ok, %{state | buckets: buckets}}
    else
      # Calculate wait time
      wait_ms = round(1000 / bucket.rate)
      buckets = Map.put(state.buckets, key, bucket)
      {:reply, {:rate_limited, wait_ms}, %{state | buckets: buckets}}
    end
  end

  @impl true
  def handle_call({:consume, channel_id, account_id}, _from, state) do
    key = {channel_id, account_id}
    now = System.monotonic_time(:millisecond)

    bucket = Map.get(state.buckets, key, new_bucket(now))
    bucket = refill_bucket(bucket, now)

    if bucket.tokens >= 1 do
      # Consume a token atomically
      bucket = %{bucket | tokens: bucket.tokens - 1}
      buckets = Map.put(state.buckets, key, bucket)
      {:reply, :ok, %{state | buckets: buckets}}
    else
      # Calculate wait time
      wait_ms = round(1000 / bucket.rate)
      buckets = Map.put(state.buckets, key, bucket)
      {:reply, {:rate_limited, wait_ms}, %{state | buckets: buckets}}
    end
  end

  def handle_call({:status, channel_id, account_id}, _from, state) do
    key = {channel_id, account_id}
    now = System.monotonic_time(:millisecond)

    bucket = Map.get(state.buckets, key, new_bucket(now))
    bucket = refill_bucket(bucket, now)

    status = %{
      tokens: bucket.tokens,
      rate: bucket.rate,
      burst: bucket.burst
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:record, channel_id, account_id}, state) do
    key = {channel_id, account_id}
    now = System.monotonic_time(:millisecond)

    bucket = Map.get(state.buckets, key, new_bucket(now))
    bucket = refill_bucket(bucket, now)
    bucket = %{bucket | tokens: max(0, bucket.tokens - 1)}

    buckets = Map.put(state.buckets, key, bucket)
    {:noreply, %{state | buckets: buckets}}
  end

  defp new_bucket(now) do
    %{
      tokens: @default_burst,
      rate: @default_rate,
      burst: @default_burst,
      last_refill: now
    }
  end

  defp refill_bucket(bucket, now) do
    elapsed_ms = now - bucket.last_refill
    tokens_to_add = elapsed_ms * bucket.rate / 1000

    new_tokens = min(bucket.burst, bucket.tokens + tokens_to_add)

    %{bucket | tokens: new_tokens, last_refill: now}
  end
end
