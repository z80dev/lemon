defmodule LemonCore.RateLimiter do
  @moduledoc """
  Shared ETS-backed limiter with application-owned supervision.

  The default outbox profile is a 30/second token bucket with a burst of five.
  The `:login` profile records failures in a bounded five-failure minute window;
  `clear/1` resets successful logins. The `:a2a` profile uses a sliding minute
  window and a live `:limit` callback. Idle peers are periodically evicted.
  Pass `:name` to retain the owning application’s registered process identity.
  `:clock` injects a monotonic millisecond clock for deterministic A2A tests.
  Provider limiting stays in the independent lemon_ai foundation package.
  """
  use GenServer

  @default_rate 30
  @default_burst 5
  @table :lemon_channels_outbox_rate_limits

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, LemonChannels.Outbox.RateLimiter),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts,
      name: Keyword.get(opts, :name, LemonChannels.Outbox.RateLimiter)
    )
  end

  @impl true
  def init(opts) when is_list(opts) do
    profile = Keyword.get(opts, :profile, :outbox)
    table = Keyword.get(opts, :name, LemonChannels.Outbox.RateLimiter)

    :ets.new(if(profile == :outbox, do: @table, else: table), [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    state = %{
      profile: profile,
      table: table,
      clock: clock,
      limit: Keyword.get(opts, :limit, 60),
      idle_ms: Keyword.get(opts, :idle_ms, 60_001)
    }

    if profile == :a2a, do: :ets.insert(table, {:policy, clock, state.limit})
    if profile == :a2a, do: Process.send_after(self(), :sweep, state.idle_ms)
    {:ok, state}
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

  defp access(key, operation) do
    if Process.whereis(LemonChannels.Outbox.RateLimiter) do
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
  @max_failures 5
  @window_ms 60_000
  @max_peers 1_024

  @doc "Returns `:ok` or `{:error, :throttled, retry_after_seconds}`."
  @spec check(term()) :: :ok | {:error, :throttled, pos_integer()}
  def check(peer) do
    now = now_ms()

    case :ets.lookup(LemonWeb.LoginThrottle, peer) do
      [{^peer, count, started}] when count >= @max_failures and now - started < @window_ms ->
        {:error, :throttled, max(div(@window_ms - (now - started), 1000), 1)}

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Records one failed attempt from `peer`."
  @spec record_failure(term()) :: :ok
  def record_failure(peer), do: GenServer.call(LemonWeb.LoginThrottle, {:failure, peer})

  @doc "Clears `peer` after a successful login."
  @spec clear(term()) :: :ok
  def clear(peer) do
    :ets.delete(LemonWeb.LoginThrottle, peer)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def handle_call({:failure, peer}, _from, state) do
    now = now_ms()

    case :ets.lookup(LemonWeb.LoginThrottle, peer) do
      [{^peer, count, started}] when now - started < @window_ms ->
        :ets.insert(LemonWeb.LoginThrottle, {peer, count + 1, started})

      _ ->
        bound_table(now)
        :ets.insert(LemonWeb.LoginThrottle, {peer, 1, now})
    end

    {:reply, :ok, state}
  end

  defp bound_table(now) do
    if :ets.info(LemonWeb.LoginThrottle, :size) >= @max_peers do
      :ets.select_delete(LemonWeb.LoginThrottle, [
        {{:_, :_, :"$1"}, [{:<, :"$1", now - @window_ms}], [true]}
      ])

      if :ets.info(LemonWeb.LoginThrottle, :size) >= @max_peers do
        LemonWeb.LoginThrottle
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_peer, _count, started} -> started end)
        |> Enum.take(div(@max_peers, 4))
        |> Enum.each(fn {peer, _, _} -> :ets.delete(LemonWeb.LoginThrottle, peer) end)
      end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  @doc "Atomically admit an A2A peer against its sliding-minute policy."
  def allow?(peer), do: allow?(LemonControlPlane.A2A.RateLimiter, peer)

  def allow?(table, peer) do
    [{:policy, clock, limit}] = :ets.lookup(table, :policy)
    sliding_window(table, peer, clock.(), if(is_function(limit, 0), do: limit.(), else: limit))
  end

  defp sliding_window(table, peer, now, limit) do
    _ = :ets.insert_new(table, {peer, [], now})

    case :ets.lookup(table, peer) do
      [{^peer, timestamps, touched}] ->
        recent = Enum.filter(timestamps, &(&1 >= now - 60_000))
        allowed = length(recent) < limit
        next_timestamps = if(allowed, do: [now | recent], else: recent)

        spec = [
          {{:"$1", :"$2", :"$3"},
           [
             {:"=:=", :"$1", {:const, peer}},
             {:"=:=", :"$2", {:const, timestamps}},
             {:"=:=", :"$3", {:const, touched}}
           ], [{{:"$1", {:const, next_timestamps}, {:const, max(now, touched)}}}]}
        ]

        if :ets.select_replace(table, spec) == 1,
          do: allowed,
          else: sliding_window(table, peer, now, limit)

      [] ->
        sliding_window(table, peer, now, limit)
    end
  end

  @impl true
  def handle_info(:sweep, %{profile: :a2a} = state) do
    cutoff = state.clock.() - state.idle_ms

    :ets.select_delete(state.table, [
      {{:"$1", :_, :"$2"},
       [{:"=/=", :"$1", :policy}, {:is_integer, :"$2"}, {:"=<", :"$2", cutoff}], [true]}
    ])

    Process.send_after(self(), :sweep, state.idle_ms)
    {:noreply, state}
  end
end
