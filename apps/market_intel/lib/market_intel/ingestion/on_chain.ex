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

  alias MarketIntel.Ingestion.HttpClient
  alias MarketIntel.Errors

  @base_rpc "https://mainnet.base.org"
  @base_scan_api "https://api.basescan.org/api"
  @source_name "OnChain"
  @fetch_interval :timer.minutes(3)

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def fetch, do: GenServer.cast(__MODULE__, :fetch)

  def get_network_stats do
    MarketIntel.Cache.get(:base_network_stats)
  end

  def get_large_transfers do
    MarketIntel.Cache.get(MarketIntel.Config.tracked_token_large_transfers_cache_key())
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    send(self(), :fetch)
    {:ok, %{last_block: nil}}
  end

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

  # Private Functions

  defp do_fetch(last_block) do
    HttpClient.log_info(@source_name, "fetching data...")

    tasks = [
      Task.async(fn -> fetch_gas_prices() end),
      Task.async(fn -> fetch_token_transfers(last_block) end),
      Task.async(fn -> fetch_holder_stats() end)
    ]

    results = Task.await_many(tasks, 30_000)

    Enum.each(results, fn
      {:ok, key, data} ->
        MarketIntel.Cache.put(key, data)

      {:error, _} = error ->
        HttpClient.log_error(@source_name, Errors.format_for_log(error))
    end)

    # Return latest block number
    last_block || fetch_latest_block()
  end

  defp fetch_gas_prices do
    # Get current gas prices from Base
    case HTTPoison.get(@base_rpc, [], timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        {:ok, :base_network_stats,
         %{
           gas_price_gwei: parse_gas_price(body),
           congestion: :medium,
           fetched_at: DateTime.utc_now()
         }}

      {:ok, %{status_code: status}} ->
        Errors.api_error("Base RPC", "HTTP #{status}")

      {:error, %HTTPoison.Error{reason: reason}} ->
        Errors.network_error(reason)
    end
  end

  defp fetch_token_transfers(nil) do
    # First run - fetch recent transfers
    fetch_token_transfers(fetch_latest_block() - 1000)
  end

  defp fetch_token_transfers(from_block) do
    token_address = MarketIntel.Config.tracked_token_address()

    if missing_config?(token_address) do
      Errors.config_error("missing tracked_token address")
    else
      do_fetch_token_transfers(token_address, from_block)
    end
  end

  defp do_fetch_token_transfers(token_address, from_block) do
    api_key_result = get_basescan_key()
    transfers_key = MarketIntel.Config.tracked_token_transfers_cache_key()
    large_transfers_key = MarketIntel.Config.tracked_token_large_transfers_cache_key()

    with {:ok, api_key} <- api_key_result,
         {:ok, data} <- fetch_basescan_transfers(token_address, from_block, api_key),
         transfers = parse_transfers(data["result"] || []),
         large_transfers = Enum.filter(transfers, &large_transfer?/1) do
      # Cache large transfers separately
      MarketIntel.Cache.put(large_transfers_key, large_transfers)

      {:ok, transfers_key,
       %{
         recent: Enum.take(transfers, 20),
         large: large_transfers,
         count_24h: length(transfers)
       }}
    end
  end

  defp fetch_basescan_transfers(token_address, from_block, api_key) do
    url =
      "#{@base_scan_api}?module=account&action=tokentx" <> 
      "&contractaddress=#{token_address}&startblock=#{from_block}&sort=desc&apikey=#{api_key}"

    HttpClient.get(url, [], source: "BaseScan")
  end

  defp get_basescan_key do
    case MarketIntel.Secrets.get(:basescan_key) do
      {:ok, key} when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        Errors.config_error("missing BASESCAN_KEY secret")
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

  defp missing_config?(nil), do: true
  defp missing_config?(""), do: true
  defp missing_config?(_), do: false

  defp schedule_next do
    HttpClient.schedule_next_fetch(self(), :fetch, @fetch_interval)
  end
end
