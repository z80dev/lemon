# MarketIntel App

Market data ingestion and AI commentary generation for the Lemon platform.

## Purpose and Responsibilities

MarketIntel is a data pipeline that:

1. **Ingests market data** from multiple sources (DEX Screener, Polymarket, BaseScan, Twitter/X)
2. **Caches hot data** in ETS for fast access
3. **Persists time-series data** in SQLite for historical analysis
4. **Generates AI commentary** based on market conditions and triggers
5. **Posts to X/Twitter** via LemonChannels integration

The app runs as an OTP application with supervised GenServer workers for each data source.

## Data Ingestion Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    MarketIntel.Application                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Cache     │  │    Repo     │  │     Scheduler       │  │
│  │   (ETS)     │  │  (SQLite)   │  │   (GenServer)       │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         │                │                     │             │
│  ┌──────┴────────────────┴─────────────────────┴──────────┐  │
│  │              Ingestion Workers (GenServers)            │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │  │
│  │  │DexScreener│ │Polymarket│ │OnChain   │ │Twitter   │   │  │
│  │  │(2min)    │ │(5min)    │ │(3min)    │ │Mentions  │   │  │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │  │
│  └─────────────────────────────────────────────────────────┘  │
│                          │                                    │
│  ┌───────────────────────┴───────────────────────────────┐    │
│  │              Commentary.Pipeline (GenStage)            │    │
│  │  ┌─────────────┐    ┌─────────────┐    ┌───────────┐  │    │
│  │  │PromptBuilder│ -> │  AI Gen     │ -> │  X Post   │  │    │
│  │  └─────────────┘    └─────────────┘    └───────────┘  │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### Ingestion Flow

1. Each ingestion worker fetches data on its interval via HTTP
2. Data is parsed and stored in `MarketIntel.Cache` (ETS with TTL)
3. Important data is persisted to `MarketIntel.Repo` (SQLite)
4. Significant events trigger the commentary pipeline

### Key Modules

| Module | Purpose | Interval |
|--------|---------|----------|
| `Ingestion.DexScreener` | Token prices, volume, mcap | 2 min |
| `Ingestion.Polymarket` | Prediction markets, trending | 5 min |
| `Ingestion.OnChain` | Base transfers, gas prices | 3 min |
| `Ingestion.TwitterMentions` | Mentions, sentiment | 2 min |

## How to Add a New Data Source

1. **Create the worker module** in `lib/market_intel/ingestion/`:

```elixir
defmodule MarketIntel.Ingestion.NewSource do
  use GenServer
  require Logger
  alias MarketIntel.Ingestion.HttpClient
  alias MarketIntel.Errors

  @source_name "NewSource"
  @fetch_interval :timer.minutes(5)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def fetch, do: GenServer.cast(__MODULE__, :fetch)

  @impl true
  def init(_opts) do
    send(self(), :fetch)
    {:ok, %{last_fetch: nil}}
  end

  @impl true
  def handle_info(:fetch, state) do
    do_fetch()
    schedule_next()
    {:noreply, %{state | last_fetch: DateTime.utc_now()}}
  end

  defp do_fetch do
    HttpClient.log_info(@source_name, "fetching...")
    # Fetch, parse, cache logic here
  end

  defp schedule_next do
    HttpClient.schedule_next_fetch(self(), :fetch, @fetch_interval)
  end
end
```

2. **Add to supervision tree** in `MarketIntel.Application`:

```elixir
children = [
  # ... existing workers
  MarketIntel.Ingestion.NewSource
]
```

3. **Add tests** in `test/market_intel/ingestion/new_source_test.exs`

4. **Add fixtures** for API responses in `test/fixtures/`

## Commentary Pipeline

The `Commentary.Pipeline` is a GenStage producer-consumer that generates market commentary tweets.

### Triggers

| Trigger | When | Example |
|---------|------|---------|
| `:scheduled` | Every 30 min via Scheduler | Regular market update |
| `:price_spike` | Price change > threshold | "LEM pumped 15%" |
| `:price_drop` | Significant drop | "Price drop commentary" |
| `:mention_reply` | High-engagement mention | Reply to influencer |
| `:weird_market` | Unusual Polymarket | UFO prediction markets |
| `:volume_surge` | Unusual trading volume | Volume spike alert |
| `:manual` | User request | Immediate generation |

### Vibes

The `PromptBuilder` supports multiple commentary styles:

- `:crypto_commentary` - Market analysis, roast ETH gas
- `:gaming_joke` - Retro gaming references, speedrun metaphors
- `:agent_self_aware` - BEAM runtime, memory files, Python comparisons
- `:lemon_persona` - Lemon platform voice, developer references

### Usage

```elixir
# Trigger commentary manually
MarketIntel.Commentary.Pipeline.trigger(:manual, %{immediate: true})

# Check pipeline state
:sys.get_state(MarketIntel.Commentary.Pipeline)
```

## Caching Strategy

**Two-tier approach:**

### Hot Cache (ETS)
- Module: `MarketIntel.Cache`
- TTL: 5 minutes default
- Use case: Fast access for commentary generation
- Keys:
  - `:tracked_token_price` - Token price data
  - `:eth_price` - ETH price
  - `:base_ecosystem` - Top Base tokens
  - `:polymarket_trending` - Trending markets
  - `:recent_mentions` - Social mentions
  - `:mention_sentiment` - Sentiment summary

### Persistent Storage (SQLite)
- Module: `MarketIntel.Repo`
- Use case: Historical analysis, auditing
- Tables: `price_snapshots`, `mention_events`, `commentary_history`, `market_signals`

### Cache Operations

```elixir
# Store with TTL
MarketIntel.Cache.put(:key, value, :timer.minutes(10))

# Retrieve
{:ok, value} = MarketIntel.Cache.get(:key)  # or :expired, :not_found

# Get full snapshot
snapshot = MarketIntel.Cache.get_snapshot()
```

## Scheduling

The `MarketIntel.Scheduler` GenServer handles periodic tasks:

| Task | Interval | Action |
|------|----------|--------|
| Regular commentary | 30 min | `Pipeline.trigger(:scheduled, %{time_of_day: "morning"})` |
| Deep analysis | 2 hours | Generate longer-form thread content |

Data sources have their own internal scheduling via `Process.send_after/3`.

### Schedule Modification

```elixir
# In Scheduler.init/1 or via config
schedule_regular()  # Every 30 min
schedule_deep_analysis()  # Every 2 hours
```

## Database Schema

SQLite via Ecto with the following tables:

### price_snapshots
```elixir
%{
  token_symbol: :string,
  token_address: :string,
  price_usd: :decimal,
  price_eth: :decimal,
  market_cap: :decimal,
  liquidity_usd: :decimal,
  volume_24h: :decimal,
  price_change_24h: :decimal,
  source: :string
}
```

### mention_events
```elixir
%{
  platform: :string,           # "twitter", "telegram", etc.
  author_handle: :string,
  content: :text,
  sentiment: :string,          # "positive", "negative", "neutral"
  engagement_score: :integer,
  mentioned_tokens: {:array, :string},
  raw_metadata: :map
}
```

### commentary_history
```elixir
%{
  tweet_id: :string,
  content: :text,
  trigger_event: :string,
  market_context: :map,
  engagement_metrics: :map
}
```

### market_signals
```elixir
%{
  signal_type: :string,        # "price_spike", "large_transfer", etc.
  severity: :string,           # "low", "medium", "high"
  description: :text,
  data: :map,
  acknowledged: :boolean
}
```

## Common Tasks and Examples

### Manual Data Fetch

```elixir
# Fetch all sources immediately
MarketIntel.Ingestion.DexScreener.fetch()
MarketIntel.Ingestion.Polymarket.fetch()
MarketIntel.Ingestion.OnChain.fetch()
```

### Check Current Data

```elixir
# Get cached prices
MarketIntel.Cache.get(:tracked_token_price)
MarketIntel.Ingestion.DexScreener.get_tracked_token_data()

# Get Polymarket data
MarketIntel.Ingestion.Polymarket.get_trending()

# Get on-chain stats
MarketIntel.Ingestion.OnChain.get_network_stats()
MarketIntel.Ingestion.OnChain.get_large_transfers()
```

### Configuration

```elixir
# Get tracked token config
MarketIntel.Config.tracked_token_symbol()
MarketIntel.Config.tracked_token_address()

# Check commentary persona
MarketIntel.Config.commentary_voice()
MarketIntel.Config.commentary_handle()
```

### Secrets Management

```elixir
# Check if secret is configured
MarketIntel.Secrets.configured?(:basescan_key)

# Get secret value
{:ok, key} = MarketIntel.Secrets.get(:basescan_key)

# View all configured (masked)
MarketIntel.Secrets.all_configured()
```

### Error Handling

```elixir
alias MarketIntel.Errors

# Create standardized errors
Errors.api_error("Source", "reason")
Errors.network_error(:timeout)
Errors.parse_error("invalid JSON")
Errors.config_error("missing key")

# Format for logging
Errors.format_for_log({:error, %{type: :api_error, source: "API", reason: "fail"}})
# => "API error from API: fail"
```

## Testing Guidance

### Test Structure

```
test/market_intel/
├── ingestion/
│   ├── dex_screener_test.exs
│   ├── polymarket_test.exs
│   ├── on_chain_test.exs
│   ├── twitter_mentions_test.exs
│   └── http_client_test.exs
├── commentary/
│   ├── pipeline_test.exs
│   └── prompt_builder_test.exs
├── cache_test.exs
├── config_test.exs
├── errors_test.exs
├── scheduler_test.exs
├── schema_test.exs
└── secrets_test.exs
```

### Running Tests

```bash
# All market_intel tests
mix test apps/market_intel

# Specific module
mix test apps/market_intel/test/market_intel/ingestion/dex_screener_test.exs

# With coverage
mix test apps/market_intel --cover
```

### Mocking HTTP

Tests use Mox to mock HTTPoison:

```elixir
defmodule MarketIntel.Ingestion.DexScreenerTest do
  use ExUnit.Case
  import Mox

  setup do
    HTTPoisonMock
    |> stub(:get, fn _url, _headers, _opts ->
      {:ok, %{status_code: 200, body: File.read!("test/fixtures/dex_screener_token_response.json")}}
    end)
    
    {:ok, _} = start_supervised(MarketIntel.Cache)
    :ok
  end
end
```

### Test Fixtures

Store API response samples in `test/fixtures/`:
- `dex_screener_token_response.json`
- `polymarket_markets_response.json`
- `basescan_transfers_response.json`
- `twitter_mentions_response.json`

### Ecto Testing

```elixir
# Setup repo in test
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(MarketIntel.Repo)
end

# Test schema changesets
test "price snapshot changeset" do
  attrs = %{token_symbol: "LEM", price_usd: "1.50"}
  changeset = PriceSnapshot.changeset(%PriceSnapshot{}, attrs)
  assert changeset.valid?
end
```

### Environment Variables for Testing

Set in `config/test.exs` or via env:

```bash
export MARKET_INTEL_BASESCAN_KEY=test_key
export MARKET_INTEL_DEXSCREENER_KEY=test_key
```

---

**Dependencies:** `lemon_core`, `agent_core`, `lemon_channels`, `httpoison`, `jason`, `ecto_sql`, `ecto_sqlite3`, `gen_stage`, `mox`
