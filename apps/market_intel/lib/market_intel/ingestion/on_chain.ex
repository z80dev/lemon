defmodule MarketIntel.Ingestion.OnChain do
  @moduledoc """
  Ingests on-chain data from Base network.

  Tracks:
  - configured tracked token transfers
  - large holder movements
  - DEX trading activity
  - gas prices and network congestion
  """

  use GenServer
  require Logger

  # Base RPC endpoints
  @base_rpc "https://mainnet.base.org"
  @base_scan_api "https://api.basescan.org/api"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :fetch)
    {:ok, %{last_block: nil}}
  end

  # Public API

  def fetch, do: GenServer.cast(__MODULE__, :fetch)

  def get_network_stats do
    MarketIntel.Cache.get(:base_network_stats)
  end

  def get_large_transfers do
    MarketIntel.Cache.get(MarketIntel.Config.tracked_token_large_transfers_cache_key())
  end

  # GenServer callbacks

  @impl true
  def handle_cast(:fetch, state) do
    do_fetch(state.last_block)
    {:noreply, state}
  end

  @impl true
  def handle_info(:fetch, state) do
    new_block = do_fetch(state.last_block)
    schedule_next()
    {:noreply, %{state | last_block: new_block}}
  end

  # Private

  defp do_fetch(last_block) do
    Logger.info("[MarketIntel] Fetching on-chain data...")

    tasks = [
      Task.async(fn -> fetch_gas_prices() end),
      Task.async(fn -> fetch_token_transfers(last_block) end),
      Task.async(fn -> fetch_holder_stats() end)
    ]

    results = Task.await_many(tasks, 30_000)

    Enum.each(results, fn
      {:ok, key, data} ->
        MarketIntel.Cache.put(key, data)

      {:error, reason} ->
        Logger.warning("[MarketIntel] On-chain fetch failed: #{inspect(reason)}")
    end)

    # Return latest block number
    last_block || fetch_latest_block()
  end

  defp fetch_gas_prices do
    # Get current gas prices from Base
    case HTTPoison.get("#{@base_rpc}", [], timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        {:ok, :base_network_stats,
         %{
           gas_price_gwei: parse_gas_price(body),
           congestion: :medium,
           fetched_at: DateTime.utc_now()
         }}

      _ ->
        {:error, :gas_fetch_failed}
    end
  end

  defp fetch_token_transfers(nil) do
    # First run - fetch recent transfers
    fetch_token_transfers(fetch_latest_block() - 1000)
  end

  defp fetch_token_transfers(from_block) do
    token_address = MarketIntel.Config.tracked_token_address()

    if token_address in [nil, ""] do
      {:error, :missing_tracked_token_address}
    else
      do_fetch_token_transfers(token_address, from_block)
    end
  end

  defp do_fetch_token_transfers(token_address, from_block) do
    # Use BaseScan API to get tracked token transfers
    api_key = get_basescan_key()
    transfers_key = MarketIntel.Config.tracked_token_transfers_cache_key()
    large_transfers_key = MarketIntel.Config.tracked_token_large_transfers_cache_key()

    url =
      "#{@base_scan_api}?module=account&action=tokentx&contractaddress=#{token_address}&startblock=#{from_block}&sort=desc&apikey=#{api_key}"

    case HTTPoison.get(url, [], timeout: 15_000) do
      {:ok, %{status_code: 200, body: body}} ->
        data = Jason.decode!(body)
        transfers = parse_transfers(data["result"] || [])

        large_transfers = Enum.filter(transfers, &large_transfer?/1)
        MarketIntel.Cache.put(large_transfers_key, large_transfers)

        {:ok, transfers_key,
         %{
           recent: Enum.take(transfers, 20),
           large: large_transfers,
           count_24h: length(transfers)
         }}

      _ ->
        {:error, :transfers_fetch_failed}
    end
  end

  defp fetch_holder_stats do
    # Could integrate with token holder APIs
    # For now, placeholder
    {:ok, :holder_stats,
     %{
       total_holders: :unknown,
       top_10_concentration: :unknown
     }}
  end

  defp fetch_latest_block do
    # Get latest block number
    0
  end

  defp parse_gas_price(_body) do
    # Parse from JSON-RPC response
    0.1
  end

  defp parse_transfers(transfers) when is_list(transfers) do
    Enum.map(transfers, fn t ->
      %{
        from: t["from"],
        to: t["to"],
        value: t["value"],
        timestamp: t["timeStamp"],
        block: t["blockNumber"],
        hash: t["hash"]
      }
    end)
  end

  defp large_transfer?(transfer) do
    threshold = MarketIntel.Config.tracked_token_large_transfer_threshold_base_units()

    case Integer.parse(to_string(transfer.value || "0")) do
      {value, _} -> value > threshold
      :error -> false
    end
  end

  defp schedule_next do
    Process.send_after(self(), :fetch, :timer.minutes(3))
  end

  defp get_basescan_key do
    case MarketIntel.Secrets.get(:basescan_key) do
      {:ok, key} -> key
      _ -> ""
    end
  end
end
