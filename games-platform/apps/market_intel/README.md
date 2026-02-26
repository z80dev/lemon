# MarketIntel

Real-time market data ingestion and commentary generation for configurable agent accounts.

## Overview

MarketIntel ingests data from multiple sources, caches it in ETS, persists to SQLite, and generates witty market commentary tweets.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Data Sources                           │
├──────────────┬──────────────┬──────────────┬────────────────┤
│ DEX Screener │  Polymarket  │    Twitter   │   On-Chain     │
│   (prices)   │(predictions) │  (mentions)  │  (Base data)   │
└──────┬───────┴──────┬───────┴──────┬───────┴────────┬───────┘
       │              │              │                │
       └──────────────┴──────────────┴────────────────┘
                          │
                          ▼
              ┌───────────────────────┐
              │    ETS Cache (hot)    │
              │   - Latest prices     │
              │   - Trending markets  │
              │   - Mention sentiment │
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │  SQLite (persistent)  │
              │   - Price history     │
              │   - Commentary log    │
              │   - Signal tracking   │
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │ Commentary Pipeline   │
              │   - Prompt building   │
              │   - AI generation     │
              │   - Tweet posting     │
              └───────────────────────┘
```

## Components

### Ingestion Workers

- **DexScreener** - Token prices, volume, market cap (every 2 min)
- **Polymarket** - Prediction market trends, weird markets (every 5 min)
- **TwitterMentions** - configured account mentions, sentiment (every 2 min)
- **OnChain** - Base network stats, large transfers (every 3 min)

### Commentary Generation

Triggered by:
- **Scheduled** - Every 30 minutes
- **Price Spike** - >10% movement
- **Price Drop** - >10% drop
- **Mention Reply** - High-engagement mentions
- **Weird Market** - Interesting Polymarket events
- **Manual** - On-demand

### Vibes/Themes

The commentary rotates through:
1. **Crypto Commentary** - Market analysis, ETH/Base jokes
2. **Gaming Jokes** - Retro games, speedrunning metaphors
3. **Agent Self-Awareness** - BEAM runtime, memory files, being a bot
4. **Lemon Persona** - Lemon house style configured via `:commentary_persona`

## Usage

### Start the application

```bash
cd ~/dev/lemon
mix deps.get
mix ecto.setup  # Create SQLite database
iex -S mix
```

### Manual commentary

```elixir
# Generate commentary immediately
MarketIntel.Commentary.Pipeline.generate_now()

# Trigger specific type
MarketIntel.Commentary.Pipeline.trigger(:price_spike, %{change: 15.5})
```

### Check data

```elixir
# Get latest tracked token price
MarketIntel.Ingestion.DexScreener.get_tracked_token_data()

# Get trending Polymarkets
MarketIntel.Ingestion.Polymarket.get_trending()

# Get recent mentions
MarketIntel.Ingestion.TwitterMentions.get_recent_mentions()

# Get full market snapshot
MarketIntel.Cache.get_snapshot()
```

## Configuration

MarketIntel uses **LemonCore.Secrets** for secure API key storage. This is more secure than environment variables and integrates with Lemon's existing secret management.

### Required: X (Twitter) API

The X API credentials are shared with `lemon_channels` and should already be configured. If not, set them via environment variables (for initial setup):

```bash
export X_API_CLIENT_ID="your_client_id"
export X_API_CLIENT_SECRET="your_client_secret"
export X_API_ACCESS_TOKEN="your_access_token"
export X_API_REFRESH_TOKEN="your_refresh_token"
```

Get your X API credentials at: https://developer.twitter.com

### Optional: Data Source Secrets

Store these in the secrets store for better security:

```bash
# Add secrets using the CLI
elixir scripts/secrets.exs set basescan_key "your_basescan_key"
elixir scripts/secrets.exs set openai_key "sk-..."

# Or set via environment (fallback)
export MARKET_INTEL_BASESCAN_KEY="your_key"
export MARKET_INTEL_OPENAI_KEY="sk-..."
```

**Available secrets:**
- `basescan_key` - BaseScan API for on-chain data
- `dexscreener_key` - DEX Screener API (optional)
- `openai_key` - OpenAI API for AI commentary
- `anthropic_key` - Anthropic API (alternative to OpenAI)

### Quick Setup

```bash
# 1. Check which secrets are configured
elixir scripts/secrets.exs check

# 2. Add your API keys
elixir scripts/secrets.exs set basescan_key "your_key"
elixir scripts/secrets.exs set openai_key "sk-..."

# 3. Verify configuration
elixir scripts/secrets.exs list

# 4. Run full setup
elixir scripts/setup.exs
```

### Managing Secrets

```bash
# List all configured secrets
elixir scripts/secrets.exs list

# Check which secrets are available
elixir scripts/secrets.exs check

# Get a specific secret (masked)
elixir scripts/secrets.exs get basescan_key

# Set a secret
elixir scripts/secrets.exs set basescan_key "new_key"
```

## Database Schema

- **price_snapshots** - Time-series price data
- **mention_events** - Social media mentions with sentiment
- **commentary_history** - Generated tweets for analysis
- **market_signals** - Significant events detected

## File Structure

```
apps/market_intel/
├── config/
│   └── config.exs          # Configuration
├── lib/
│   ├── market_intel/
│   │   ├── application.ex  # OTP app startup
│   │   ├── cache.ex        # ETS cache
│   │   ├── repo.ex         # SQLite repo
│   │   ├── schema.ex       # Ecto schemas
│   │   ├── scheduler.ex    # Periodic tasks
│   │   ├── secrets.ex      # Secrets store helper
│   │   ├── commentary/
│   │   │   └── pipeline.ex # Tweet generation
│   │   └── ingestion/
│   │       ├── dex_screener.ex
│   │       ├── polymarket.ex
│   │       ├── twitter_mentions.ex
│   │       └── on_chain.ex
│   └── market_intel.ex     # Main module
├── priv/
│   └── repo/migrations/    # Database migrations
├── scripts/
│   ├── secrets.exs         # Secrets CLI
│   ├── check_env.exs       # Env var checker
│   └── setup.exs           # Setup script
├── README.md               # Full documentation
├── SETUP.md                # Setup guide
└── mix.exs                 # App dependencies
```

## Backlog

Known feature gaps and implementation stubs are tracked in the debt plan:
`planning/plans/PLN-20260222-debt-phase-10-monolith-footprint-reduction.md` (M1).

Key items:
- Twitter/X mention fetching is a stub (returns `[]`)
- DB persistence for commentary history and price snapshots are stub no-ops
- Deep analysis scheduler callback is a no-op
- Holder stats always return `:unknown`

See `AGENTS.md` "Implementation Status" section for current stub details.
