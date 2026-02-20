# MarketIntel

Real-time market data ingestion and commentary generation for zeebot.

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
- **TwitterMentions** - @realzeebot mentions, sentiment (every 2 min)
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
4. **Lemon Persona** - Lemonade stand metaphors, $ZEEBOT, z80 as dev

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
# Get latest ZEEBOT price
MarketIntel.Ingestion.DexScreener.get_zeebot_data()

# Get trending Polymarkets
MarketIntel.Ingestion.Polymarket.get_trending()

# Get recent mentions
MarketIntel.Ingestion.TwitterMentions.get_recent_mentions()

# Get full market snapshot
MarketIntel.Cache.get_snapshot()
```

## Configuration

Environment variables:
- `DEXSCREENER_API_KEY` - Optional API key
- `BASESCAN_API_KEY` - For on-chain data

Config in `config/config.exs`:
- Commentary intervals
- Token addresses
- Thresholds for signals

## Database Schema

- **price_snapshots** - Time-series price data
- **mention_events** - Social media mentions with sentiment
- **commentary_history** - Generated tweets for analysis
- **market_signals** - Significant events detected

## Future Enhancements

- [ ] Integration with AI module for tweet generation
- [ ] Farcaster mentions ingestion
- [ ] Telegram sentiment analysis
- [ ] Automated thread generation for deep analysis
- [ ] Performance tracking (which commentary gets best engagement)
- [ ] Backtesting commentary strategies
