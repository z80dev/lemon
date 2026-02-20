import Config

# Database configuration
config :market_intel, MarketIntel.Repo,
  database: Path.expand("../../data/market_intel.db", __DIR__),
  pool_size: 5

# MarketIntel configuration
config :market_intel,
  ecto_repos: [MarketIntel.Repo],
  
  # Secrets store configuration
  # API keys are resolved from LemonCore.Secrets at runtime
  secrets_module: LemonCore.Secrets,
  use_secrets: true,
  
  # Commentary settings (can be overridden via secrets store)
  min_commentary_interval: 1_200_000, # 20 min in ms
  max_commentary_per_hour: 3,
  
  # Enable/disable ingestors
  enable_dex: true,
  enable_polymarket: true,
  enable_twitter: true,
  enable_onchain: true,
  
  # Token addresses
  zeebot_token_address: "0x14d2ced95039eef74952cd1c1b129bad68bb0b07",
  eth_address: "0x4200000000000000000000000000000000000006",  # WETH on Base
  
  # X API configuration (inherited from lemon_channels)
  x_account_id: "2022351619589873664"
