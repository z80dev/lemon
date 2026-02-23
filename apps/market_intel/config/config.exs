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
  # 20 min in ms
  min_commentary_interval: 1_200_000,
  max_commentary_per_hour: 3,

  # Token and signal configuration
  tracked_token: [
    name: "ZEEBOT",
    symbol: "ZEEBOT",
    address: "0x14d2ced95039eef74952cd1c1b129bad68bb0b07",
    signal_key: :tracked_token,
    price_cache_key: :tracked_token_price,
    transfers_cache_key: :tracked_token_transfers,
    large_transfers_cache_key: :tracked_token_large_transfers,
    price_change_signal_threshold_pct: 10,
    large_transfer_threshold_base_units: 1_000_000_000_000_000_000_000_000
  ],
  eth_address: "0x4200000000000000000000000000000000000006",

  # X account configuration (inherited from lemon_channels auth)
  x: [
    account_id: "2022351619589873664",
    account_handle: "realzeebot"
  ],

  # Prompt persona configuration
  commentary_persona: [
    x_handle: "@realzeebot",
    voice: "witty, technical, crypto-native, occasionally self-deprecating",
    lemon_persona_instructions:
      "Use lemonade stand metaphors lightly and keep market commentary grounded in real events.",
    developer_alias: "z80"
  ]

# Ingestion feature flags live in the umbrella root config (config/config.exs)
# under `config :market_intel, :ingestion, %{...}`.  MarketIntel.Application
# reads only the :ingestion map — no per-flag keys are used here.
