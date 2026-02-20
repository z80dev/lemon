defmodule MarketIntel.Application do
  @moduledoc """
  MarketIntel OTP Application
  
  Supervises:
  - Data ingestion workers (DEX, Polymarket, Twitter, On-chain)
  - ETS cache for hot data
  - SQLite repo for persistence
  - Commentary generation pipeline
  """
  
  use Application
  
  @impl true
  def start(_type, _args) do
    children = [
      # ETS table for hot market data cache
      MarketIntel.Cache,
      
      # SQLite repo for time-series data
      MarketIntel.Repo,
      
      # Data ingestion workers
      MarketIntel.Ingestion.DexScreener,
      MarketIntel.Ingestion.Polymarket,
      MarketIntel.Ingestion.TwitterMentions,
      MarketIntel.Ingestion.OnChain,
      
      # Commentary generation pipeline
      MarketIntel.Commentary.Pipeline,
      
      # Scheduler for periodic ingestion
      MarketIntel.Scheduler
    ]
    
    opts = [strategy: :one_for_one, name: MarketIntel.Supervisor]
    Supervisor.start_link(children, opts)
  end
end