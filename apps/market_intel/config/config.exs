import Config

# Database configuration
config :market_intel, MarketIntel.Repo,
  database: Path.expand("../../data/market_intel.db", __DIR__),
  pool_size: 5

# MarketIntel configuration
config :market_intel,
  ecto_repos: [MarketIntel.Repo],
  
  # API keys (should be in env vars in production)
  dexscreener_api_key: System.get_env("DEXSCREENER_API_KEY"),
  basescan_api_key: System.get_env("BASESCAN_API_KEY"),
  
  # AI provider for commentary generation
  ai_provider: System.get_env("MARKET_INTEL_AI_PROVIDER", "openai"),
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  
  # Commentary settings
  min_commentary_interval: String.to_integer(System.get_env("MARKET_INTEL_MIN_INTERVAL") || "1200000"), # 20 min
  max_commentary_per_hour: String.to_integer(System.get_env("MARKET_INTEL_MAX_PER_HOUR") || "3"),
  
  # Enable/disable ingestors
  enable_dex: System.get_env("MARKET_INTEL_ENABLE_DEX", "true") == "true",
  enable_polymarket: System.get_env("MARKET_INTEL_ENABLE_POLYMARKET", "true") == "true",
  enable_twitter: System.get_env("MARKET_INTEL_ENABLE_TWITTER", "true") == "true",
  enable_onchain: System.get_env("MARKET_INTEL_ENABLE_ONCHAIN", "true") == "true",
  
  # Token addresses
  zeebot_token_address: "0x14d2ced95039eef74952cd1c1b129bad68bb0b07",
  eth_address: "0x4200000000000000000000000000000000000006",  # WETH on Base
  
  # X API configuration (inherited from lemon_channels)
  x_account_id: System.get_env("X_DEFAULT_ACCOUNT_ID", "2022351619589873664")
