# MarketIntel

Real-time market data ingestion, caching, and AI-powered commentary generation for the Lemon platform. MarketIntel runs as an OTP application with supervised GenServer workers that poll external data sources on configurable intervals, store results in a two-tier cache (ETS hot cache + SQLite persistence), detect significant market events via threshold-based triggers, and generate witty market commentary tweets posted to X/Twitter.

## Architecture Overview

```
                        MarketIntel.Application
                      (one_for_one supervisor)
                                |
           +--------------------+--------------------+
           |                    |                    |
      Core (always)      Ingestors (gated)     Pipeline (gated)
           |                    |                    |
   +-------+-------+    +------+------+------+------+------+
   |               |    |      |      |      |      |      |
 Cache           Repo  Dex  Poly  Twitter OnChain  Pipeline Scheduler
 (ETS)         (SQLite) Screener market Mentions          (GenStage)
                        2min   5min   2min   3min
                          |      |      |      |
                          +------+------+------+
                                 |
                          MarketIntel.Cache
                          (ETS with TTL)
                                 |
                    +------------+------------+
                    |                         |
            Price signals             Polymarket events
            (> threshold)             (weird/trending)
                    |                         |
                    +------------+------------+
                                 |
                   Commentary.Pipeline (GenStage)
                                 |
                    +------------+------------+
                    |            |            |
              PromptBuilder   AI Gen      X Post
              (struct-based) (OpenAI/    (LemonChannels
                              Anthropic)  dynamic call)
                                 |
                          SQLite storage
                       (commentary_history)
```

### Data Flow

1. **Ingestion**: GenServer workers poll external APIs on fixed intervals using `Process.send_after/3`. Each worker fetches, parses, and normalizes data from its source.
2. **Caching**: Parsed data is stored in `MarketIntel.Cache` (an ETS table with per-entry TTL). Important data is also persisted to SQLite via `MarketIntel.Repo`.
3. **Signal Detection**: After each fetch, workers check for significant events (price movements exceeding thresholds, unusual Polymarket content, high-engagement mentions). Detected events trigger the commentary pipeline.
4. **Commentary Generation**: `Commentary.Pipeline` (a GenStage producer_consumer) builds a prompt using `PromptBuilder`, generates text via an AI provider (OpenAI or Anthropic through `AgentCore.TextGeneration`), and posts the result to X via `LemonChannels`.
5. **Scheduling**: `MarketIntel.Scheduler` triggers periodic commentary (every 30 minutes for regular updates, every 2 hours for deep analysis).

## Module Inventory

### Core Infrastructure

| Module | File | Purpose |
|--------|------|---------|
| `MarketIntel` | `lib/market_intel.ex` | Top-level namespace module |
| `MarketIntel.Application` | `lib/market_intel/application.ex` | OTP application; supervises core + optional workers based on feature flags |
| `MarketIntel.Cache` | `lib/market_intel/cache.ex` | ETS-based cache with per-entry TTL, periodic cleanup, and snapshot aggregation |
| `MarketIntel.Repo` | `lib/market_intel/repo.ex` | Ecto SQLite3 repo for time-series persistence |
| `MarketIntel.Config` | `lib/market_intel/config.ex` | Centralized configuration with defaults, normalization, and legacy backfill |
| `MarketIntel.Secrets` | `lib/market_intel/secrets.ex` | Secret resolution: LemonCore.Secrets store with env var fallback |
| `MarketIntel.Errors` | `lib/market_intel/errors.ex` | Standardized error types (`:api_error`, `:parse_error`, `:network_error`, `:config_error`) |
| `MarketIntel.Schema` | `lib/market_intel/schema.ex` | Ecto schemas: `PriceSnapshot`, `MentionEvent`, `CommentaryHistory`, `MarketSignal` |
| `MarketIntel.Scheduler` | `lib/market_intel/scheduler.ex` | Periodic commentary triggers (30 min regular, 2 hour deep analysis) |

### Ingestion Workers

| Module | File | Source | Interval | Data |
|--------|------|--------|----------|------|
| `Ingestion.DexScreener` | `lib/market_intel/ingestion/dex_screener.ex` | DEX Screener REST API | 2 min | Token prices, volume, mcap, liquidity, Base ecosystem top-10 |
| `Ingestion.Polymarket` | `lib/market_intel/ingestion/polymarket.ex` | Polymarket GraphQL API | 5 min | Trending markets, crypto/AI/weird categories, high-volume markets |
| `Ingestion.TwitterMentions` | `lib/market_intel/ingestion/twitter_mentions.ex` | X/Twitter API | 2 min | Direct mentions, sentiment analysis, engagement scoring |
| `Ingestion.OnChain` | `lib/market_intel/ingestion/on_chain.ex` | Base RPC + BaseScan API | 3 min | Gas prices, token transfers, large holder movements, holder stats |
| `Ingestion.HttpClient` | `lib/market_intel/ingestion/http_client.ex` | -- | -- | Shared HTTP client with JSON parsing, error wrapping, auth headers |

### Commentary Pipeline

| Module | File | Purpose |
|--------|------|---------|
| `Commentary.Pipeline` | `lib/market_intel/commentary/pipeline.ex` | GenStage producer_consumer; receives triggers, builds prompts, generates tweets, posts to X, stores history |
| `Commentary.PromptBuilder` | `lib/market_intel/commentary/prompt_builder.ex` | Struct-based prompt construction with vibes, market context, trigger context, and output rules |

## Data Sources and Feeds

### DEX Screener (`Ingestion.DexScreener`)

- **API**: `https://api.dexscreener.com/latest`
- **Endpoints**: `/dex/tokens/{address}` (token lookup), `/dex/search?q=base` (ecosystem search)
- **Auth**: Optional Bearer token via `:dexscreener_key` secret
- **Fetches**: Tracked token price/volume/mcap, ETH price, top-10 Base ecosystem tokens by volume
- **Signals**: Triggers `Commentary.Pipeline` with `:price_spike` when 24h price change exceeds configurable threshold (default 10%)
- **Data structure**: Selects highest-liquidity pair from response

### Polymarket (`Ingestion.Polymarket`)

- **API**: `https://api.polymarket.com/graphql`
- **Query**: Top 50 active markets ordered by volume
- **Categories**: Trending (top 5), crypto-related, AI/agent-related, weird/niche, high-volume (>$1M)
- **Keyword filters**: Crypto (`bitcoin`, `ethereum`, `crypto`, `btc`, `eth`, `blockchain`, `token`), AI (`ai`, `artificial intelligence`, `chatgpt`, `openai`, `anthropic`, `agent`), Weird (`jesus`, `alien`, `ufo`, `apocalypse`)
- **Signals**: Triggers `:weird_market` commentary when niche markets are detected

### Twitter/X Mentions (`Ingestion.TwitterMentions`)

- **Status**: Fetch is currently a stub (returns `[]`); sentiment analysis and engagement scoring are implemented
- **Sentiment**: Keyword-based classification using positive (`moon`, `pump`, `bullish`), negative (`dump`, `bearish`, `scam`), and question keywords
- **Engagement score**: `likes + retweets * 2 + replies * 3`
- **Signals**: Triggers `:mention_reply` for mentions with engagement score > 10 or containing questions

### On-Chain / Base Network (`Ingestion.OnChain`)

- **APIs**: Base RPC (`https://mainnet.base.org`), BaseScan (`https://api.basescan.org/api`)
- **Auth**: Required BaseScan API key via `:basescan_key` secret
- **Fetches**: Gas prices/congestion, token transfers (from last known block), large transfer detection, holder stats (feature-gated)
- **Large transfer threshold**: Configurable, default 1M tokens (with 18 decimals = `1_000_000_000_000_000_000_000_000` base units)

## Commentary System

### Triggers

| Trigger | When | Context Keys |
|---------|------|--------------|
| `:scheduled` | Every 30 min via Scheduler | `%{time_of_day: "morning" \| "afternoon" \| ...}` |
| `:price_spike` | Price change > threshold (default 10%) | `%{token: atom, change: float}` |
| `:price_drop` | Significant drop (same threshold, negative) | `%{token: atom, change: float}` |
| `:mention_reply` | High-engagement mention (score > 10) or question | `%{mentions: list}` |
| `:weird_market` | Unusual Polymarket content detected | `%{markets: list}` |
| `:volume_surge` | Unusual trading volume | any |
| `:manual` | On-demand request | `%{immediate: true}` |

When `context[:immediate]` is true, the event is processed synchronously. Otherwise it is queued in `state.pending`.

### Vibes (Commentary Styles)

Selected randomly for each generation:

1. **`:crypto_commentary`** -- Market analysis with crypto-native language. Roasts ETH gas, celebrates Base.
2. **`:gaming_joke`** -- Retro game references (Mario, Zelda, Doom), speedrunning metaphors. Under 280 chars.
3. **`:agent_self_aware`** -- Self-referential AI content. References BEAM runtime, memory files, process isolation. Compares to Python agents.
4. **`:lemon_persona`** -- Lemon platform house style. Uses configurable `lemon_persona_instructions` and optionally references `developer_alias`.

### AI Providers

Commentary generation tries providers in order:

1. **OpenAI** (`gpt-4o-mini`) -- if `:openai_key` is configured
2. **Anthropic** (`claude-3-5-haiku-20241022`) -- if `:anthropic_key` is configured
3. **Fallback templates** -- random selection from 5+ hardcoded tweet templates

AI calls route through `AgentCore.TextGeneration.complete_text/4` to respect architecture boundaries. Tweets are truncated to 280 characters.

## Caching Strategy

### Hot Cache (ETS)

- **Module**: `MarketIntel.Cache` (GenServer owning named ETS table `:market_intel_cache`)
- **TTL**: 5 minutes default; explicit TTL via third argument to `put/3`
- **Concurrency**: Public table with `read_concurrency: true` and `write_concurrency: true`
- **Cleanup**: Every 1 minute, expired entries are deleted via `ets:select_delete/2`

Cache keys in use:

| Key | Set By | Content |
|-----|--------|---------|
| Configurable (default `:tracked_token_price`) | DexScreener | Token price, volume, mcap, liquidity map |
| `:eth_price` | DexScreener | ETH price map |
| `:base_ecosystem` | DexScreener | Top 10 Base tokens by volume |
| `:base_network_stats` | OnChain | Gas price, congestion level |
| Configurable (default `:tracked_token_transfers`) | OnChain | Recent + large transfers |
| Configurable (default `:tracked_token_large_transfers`) | OnChain | Large transfers only |
| `:holder_stats` | OnChain | Holder count (stub) |
| `:polymarket_trending` | Polymarket | Categorized markets map |
| `:recent_mentions` | TwitterMentions | Analyzed mentions with sentiment |
| `:mention_sentiment` | TwitterMentions | Sentiment summary (percentages, top mentions) |

Note: Cache keys for the tracked token are configurable via `MarketIntel.Config` functions. Do not hardcode them.

### Persistent Storage (SQLite)

- **Module**: `MarketIntel.Repo` (Ecto SQLite3 adapter)
- **Tables**: `price_snapshots`, `mention_events`, `commentary_history`, `market_signals`
- **Primary keys**: `:binary_id` (auto-generated UUIDs)
- **Timestamps**: `utc_datetime_usec`

### Cache Operations

```elixir
# Store with default TTL (5 min)
MarketIntel.Cache.put(:key, value)

# Store with custom TTL
MarketIntel.Cache.put(:key, value, :timer.minutes(10))

# Retrieve -- returns {:ok, value}, :expired, or :not_found
{:ok, value} = MarketIntel.Cache.get(:key)

# Get aggregated snapshot for commentary
snapshot = MarketIntel.Cache.get_snapshot()
# => %{token: ..., eth: ..., base: ..., polymarket: ..., mentions: ..., timestamp: DateTime}
```

## Database Schema

### price_snapshots

| Field | Type | Description |
|-------|------|-------------|
| `token_symbol` | `:string` | Token ticker symbol |
| `token_address` | `:string` | Contract address |
| `price_usd` | `:decimal` | Price in USD |
| `price_eth` | `:decimal` | Price in ETH |
| `market_cap` | `:decimal` | Market capitalization |
| `liquidity_usd` | `:decimal` | Liquidity in USD |
| `volume_24h` | `:decimal` | 24-hour trading volume |
| `price_change_24h` | `:decimal` | 24-hour price change percentage |
| `source` | `:string` | Data source identifier |

### mention_events

| Field | Type | Description |
|-------|------|-------------|
| `platform` | `:string` | Source platform (e.g. "twitter") |
| `author_handle` | `:string` | Author's handle |
| `content` | `:string` | Mention text content |
| `sentiment` | `:string` | "positive", "negative", or "neutral" |
| `engagement_score` | `:integer` | Weighted engagement score |
| `mentioned_tokens` | `{:array, :string}` | Token tickers mentioned |
| `raw_metadata` | `:map` | Original API response data |

### commentary_history

| Field | Type | Description |
|-------|------|-------------|
| `tweet_id` | `:string` | X/Twitter tweet ID (unique constraint) |
| `content` | `:string` | Tweet text content |
| `trigger_event` | `:string` | What triggered generation |
| `market_context` | `:map` | Market snapshot at generation time |
| `engagement_metrics` | `:map` | Post-publication engagement data |

### market_signals

| Field | Type | Description |
|-------|------|-------------|
| `signal_type` | `:string` | Signal category (e.g. "price_spike") |
| `severity` | `:string` | "low", "medium", or "high" |
| `description` | `:string` | Human-readable description |
| `data` | `:map` | Signal-specific data |
| `acknowledged` | `:boolean` | Whether signal has been reviewed |

## Configuration

### Feature Flags (Ingestion Workers)

Set in `config/config.exs` under `:market_intel, :ingestion`:

```elixir
config :market_intel, :ingestion, %{
  enable_dex: true,          # DexScreener price ingestion
  enable_polymarket: true,   # Polymarket prediction markets
  enable_twitter: true,      # Twitter/X mention tracking
  enable_onchain: true,      # Base on-chain data
  enable_commentary: true,   # Commentary generation pipeline
  enable_scheduler: true     # Periodic commentary scheduling
}
```

Core infrastructure (`Cache` and `Repo`) always starts regardless of flags.

### Tracked Token Configuration

Set under `:market_intel, :tracked_token`:

```elixir
config :market_intel, :tracked_token,
  name: "My Token",
  symbol: "MTK",
  address: "0x...",                                     # Contract address on Base
  signal_key: :my_token,                                # Cache signal key
  price_cache_key: :my_token_price,                     # Cache key for price data
  transfers_cache_key: :my_token_transfers,              # Cache key for transfers
  large_transfers_cache_key: :my_token_large_transfers,  # Cache key for large transfers
  price_change_signal_threshold_pct: 10,                 # % change to trigger signal
  large_transfer_threshold_base_units: 1_000_000_000_000_000_000_000_000  # 1M tokens (18 decimals)
```

Defaults are defined in `MarketIntel.Config` and used when keys are omitted.

### X/Twitter Account

Set under `:market_intel, :x`:

```elixir
config :market_intel, :x,
  account_id: "1234567890",
  account_handle: "mybot"
```

### Commentary Persona

Set under `:market_intel, :commentary_persona`:

```elixir
config :market_intel, :commentary_persona,
  x_handle: "@mybot",
  voice: "witty, technical, crypto-native, occasionally self-deprecating",
  lemon_persona_instructions: "Write in a playful Lemon house style.",
  developer_alias: "z80"
```

### Other Settings

```elixir
# ETH address for price tracking (defaults to Base WETH)
config :market_intel, :eth_address, "0x4200000000000000000000000000000000000006"

# Holder stats feature gate
config :market_intel, :holder_stats_enabled, false

# HTTP client injection (for testing)
config :market_intel, :http_client_module, HTTPoison
config :market_intel, :http_client_secrets_module, MarketIntel.Secrets

# Secrets store toggle
config :market_intel, :use_secrets, true
config :market_intel, :secrets_module, LemonCore.Secrets
```

## Secrets Management

MarketIntel uses `LemonCore.Secrets` as the primary secrets store with environment variable fallback. Resolution order: secrets store first, then `System.get_env/1`.

| Atom Key | Environment Variable | Required | Purpose |
|----------|---------------------|----------|---------|
| `:basescan_key` | `MARKET_INTEL_BASESCAN_KEY` | For on-chain data | BaseScan API key |
| `:dexscreener_key` | `MARKET_INTEL_DEXSCREENER_KEY` | Optional | DEX Screener API key |
| `:openai_key` | `MARKET_INTEL_OPENAI_KEY` | For AI commentary | OpenAI API key |
| `:anthropic_key` | `MARKET_INTEL_ANTHROPIC_KEY` | Alternative to OpenAI | Anthropic API key |
| `:x_client_id` | `X_API_CLIENT_ID` | For posting | X API client ID |
| `:x_client_secret` | `X_API_CLIENT_SECRET` | For posting | X API client secret |
| `:x_access_token` | `X_API_ACCESS_TOKEN` | For posting | X API access token |
| `:x_refresh_token` | `X_API_REFRESH_TOKEN` | For posting | X API refresh token |

```elixir
# Check configuration
MarketIntel.Secrets.configured?(:basescan_key)  # => true | false

# Get secret
{:ok, key} = MarketIntel.Secrets.get(:basescan_key)
key = MarketIntel.Secrets.get!(:basescan_key)  # raises on missing

# Store a secret
:ok = MarketIntel.Secrets.put(:basescan_key, "abc123")

# View all configured (masked values)
MarketIntel.Secrets.all_configured()
```

## Error Handling

All ingestion modules use standardized error types via `MarketIntel.Errors`:

| Type | Constructor | Use Case |
|------|------------|----------|
| `:api_error` | `Errors.api_error(source, reason)` | External API failures (HTTP 4xx/5xx) |
| `:config_error` | `Errors.config_error(reason)` | Missing configuration or secrets |
| `:parse_error` | `Errors.parse_error(reason)` | JSON decode failures, unexpected response structures |
| `:network_error` | `Errors.network_error(reason)` | Timeouts, connection refused |

```elixir
alias MarketIntel.Errors

# Create errors
Errors.api_error("Polymarket", "HTTP 500")
Errors.network_error(:timeout)

# Format for logging
Errors.format_for_log(error)  # => "API error from Polymarket: HTTP 500"

# Check type and unwrap
Errors.type?(error, :api_error)  # => true
Errors.unwrap(error)             # => "HTTP 500"
```

## Usage Examples

### Manual Data Fetch

```elixir
# Trigger fetches immediately (async, cast-based)
MarketIntel.Ingestion.DexScreener.fetch()
MarketIntel.Ingestion.Polymarket.fetch()
MarketIntel.Ingestion.OnChain.fetch()
```

### Check Current Data

```elixir
# Token price from DEX Screener
MarketIntel.Ingestion.DexScreener.get_tracked_token_data()
# => {:ok, %{price_usd: "1.23", price_change_24h: 5.5, ...}} | :not_found | :expired

# Polymarket trending
MarketIntel.Ingestion.Polymarket.get_trending()
# => {:ok, %{trending: [...], crypto_related: [...], ai_agent: [...], ...}}

# On-chain stats
MarketIntel.Ingestion.OnChain.get_network_stats()
MarketIntel.Ingestion.OnChain.get_large_transfers()

# Twitter mentions
MarketIntel.Ingestion.TwitterMentions.get_recent_mentions()
MarketIntel.Ingestion.TwitterMentions.get_sentiment_summary()

# Full market snapshot
MarketIntel.Cache.get_snapshot()
```

### Generate Commentary

```elixir
# Immediate generation
MarketIntel.Commentary.Pipeline.generate_now()

# Trigger specific type
MarketIntel.Commentary.Pipeline.trigger(:price_spike, %{change: 15.5})

# Check pipeline state
:sys.get_state(MarketIntel.Commentary.Pipeline)
```

### Build Prompts Directly

```elixir
alias MarketIntel.Commentary.PromptBuilder

builder = %PromptBuilder{
  vibe: :crypto_commentary,
  market_data: %{
    token: {:ok, %{price_usd: "1.23", price_change_24h: 5.5}},
    eth: {:ok, %{price_usd: 3500.0}},
    polymarket: {:ok, %{trending: ["event1"]}}
  },
  token_name: "Lemon Token",
  token_ticker: "$LEM",
  trigger_type: :scheduled,
  trigger_context: %{}
}

prompt = PromptBuilder.build(builder)
```

### Configuration Inspection

```elixir
MarketIntel.Config.tracked_token_name()      # "Tracked Token" (default)
MarketIntel.Config.tracked_token_ticker()     # "$TOKEN" (default)
MarketIntel.Config.tracked_token_address()    # nil (default)
MarketIntel.Config.commentary_handle()        # "@marketintel" (default)
MarketIntel.Config.commentary_voice()         # "witty, technical, ..."
MarketIntel.Config.x_account_handle()         # nil (default)
```

## Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| `httpoison` | `~> 2.0` | HTTP client for external API requests |
| `jason` | `~> 1.4` | JSON encoding/decoding |
| `ecto_sql` | `~> 3.10` | Database query layer |
| `ecto_sqlite3` | `~> 0.12` | SQLite3 adapter for Ecto |
| `gen_stage` | `~> 1.2` | Backpressure-aware pipeline (Commentary.Pipeline) |
| `mox` | `~> 1.2` | Mock definitions for testing (test only) |
| `lemon_core` | umbrella | Secrets store, shared configuration |
| `agent_core` | umbrella | AI text generation (`AgentCore.TextGeneration`) |
| `lemon_channels` | umbrella | X/Twitter posting (`runtime: false`, compile-time only) |

## Implementation Status

Several features are stubs awaiting full implementation. Known debt is tracked in `planning/plans/PLN-20260222-debt-phase-10-monolith-footprint-reduction.md` (M1).

- **Twitter/X mention fetch**: `TwitterMentions.fetch_mentions/1` returns `[]`. X API search integration is not implemented.
- **DB persistence for DexScreener**: `DexScreener.persist_to_db/2` is a no-op returning `:ok`.
- **Commentary history storage**: `Pipeline.insert_commentary_history/1` writes to SQLite when the Repo is available; degrades gracefully otherwise.
- **X posting**: Posts via `LemonChannels.Adapters.XAPI.Client.post_text/1` using dynamic module loading (`Code.ensure_loaded?`). Returns `{:error, :x_api_client_unavailable}` when the module is not present.
- **Holder stats**: OnChain holder stats are gated by `:holder_stats_enabled` config (default `false`). When enabled, fetches from BaseScan; when disabled, returns `:not_enabled`.
- **Deep analysis**: `Scheduler.handle_info(:deep_analysis, ...)` is a no-op stub.
- **Gas price parsing**: `OnChain.parse_gas_price/1` returns a hardcoded `0.1`.
- **Block tracking**: `OnChain.fetch_latest_block/0` returns `0`.

## File Structure

```
apps/market_intel/
+-- lib/
|   +-- market_intel.ex                          # Namespace module
|   +-- market_intel/
|       +-- application.ex                       # OTP app, supervision tree
|       +-- cache.ex                             # ETS cache with TTL
|       +-- config.ex                            # Centralized config with defaults
|       +-- errors.ex                            # Standardized error types
|       +-- repo.ex                              # Ecto SQLite3 repo
|       +-- schema.ex                            # PriceSnapshot, MentionEvent, CommentaryHistory, MarketSignal
|       +-- scheduler.ex                         # Periodic commentary triggers
|       +-- secrets.ex                           # Secret resolution (store + env fallback)
|       +-- commentary/
|       |   +-- pipeline.ex                      # GenStage commentary generation
|       |   +-- prompt_builder.ex                # Struct-based prompt construction
|       +-- ingestion/
|           +-- dex_screener.ex                  # DEX Screener API worker
|           +-- http_client.ex                   # Shared HTTP client helpers
|           +-- on_chain.ex                      # Base RPC + BaseScan worker
|           +-- polymarket.ex                    # Polymarket GraphQL worker
|           +-- twitter_mentions.ex              # Twitter/X mention worker
+-- test/
|   +-- test_helper.exs                          # Mox definitions
|   +-- market_intel_test.exs                    # Top-level cache tests
|   +-- market_intel/
|       +-- cache_test.exs
|       +-- config_test.exs
|       +-- errors_test.exs
|       +-- schema_test.exs
|       +-- scheduler_test.exs
|       +-- secrets_test.exs
|       +-- trigger_system_test.exs
|       +-- commentary/
|       |   +-- commentary_history_db_test.exs
|       |   +-- pipeline_test.exs
|       |   +-- prompt_builder_test.exs
|       +-- ingestion/
|           +-- dex_screener_test.exs
|           +-- http_client_test.exs
|           +-- on_chain_test.exs
|           +-- polymarket_test.exs
|           +-- twitter_mentions_test.exs
+-- mix.exs
```
