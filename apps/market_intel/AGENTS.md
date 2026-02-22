# MarketIntel App

Market data ingestion and AI commentary generation for the Lemon platform.

## Purpose and Responsibilities

MarketIntel is a data pipeline that:

1. **Ingests market data** from multiple sources (DEX Screener, Polymarket, BaseScan, Twitter/X)
2. **Caches hot data** in ETS for fast access
3. **Persists time-series data** in SQLite for historical analysis
4. **Generates AI commentary** based on market conditions and triggers
5. **Posts to X/Twitter** via LemonChannels integration (runtime-optional)

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

1. Each ingestion worker fetches data on its interval via `Process.send_after/3`
2. Data is parsed and stored in `MarketIntel.Cache` (ETS with TTL)
3. Important data is persisted to `MarketIntel.Repo` (SQLite) — persistence stubs exist but are not yet fully implemented
4. Significant events trigger the commentary pipeline

### Key Modules

| Module | Purpose | Interval |
|--------|---------|----------|
| `Ingestion.DexScreener` | Token prices, volume, mcap from DEX Screener API | 2 min |
| `Ingestion.Polymarket` | Prediction markets via GraphQL | 5 min |
| `Ingestion.OnChain` | Base transfers via BaseScan, gas via Base RPC | 3 min |
| `Ingestion.TwitterMentions` | Mentions, sentiment (fetch is a stub — returns `[]`) | 2 min |

## Implementation Status

Several features are stubs awaiting full implementation:

- **AI generation**: `generate_with_openai/1` and `generate_with_anthropic/1` both return `{:error, :not_implemented}`. Commentary uses fallback templates instead.
- **Twitter fetch**: `TwitterMentions.fetch_mentions/1` returns `[]`. X API integration is not implemented.
- **DB persistence**: `insert_commentary_history/1` is a public stub that only logs. `DexScreener.persist_to_db/2` is also a no-op stub.
- **X posting**: `lemon_channels` is a `runtime: false` compile-time dep. Posting calls `LemonChannels.Adapters.XAPI.Client.post_text/1` dynamically with `Code.ensure_loaded?`.

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

  # Public API: cast-based for manual trigger
  def fetch, do: GenServer.cast(__MODULE__, :fetch)

  @impl true
  def init(_opts) do
    send(self(), :fetch)
    {:ok, %{last_fetch: nil}}
  end

  # Scheduled fetch via Process.send_after
  @impl true
  def handle_info(:fetch, state) do
    do_fetch()
    schedule_next()
    {:noreply, %{state | last_fetch: DateTime.utc_now()}}
  end

  # Manual fetch via cast
  @impl true
  def handle_cast(:fetch, state) do
    do_fetch()
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

`Commentary.Pipeline` is a GenStage `:producer_consumer` that generates market commentary tweets. It has no upstream producers — all events enter via `GenStage.cast/2`.

### Triggers

| Trigger | When | Context keys |
|---------|------|--------------|
| `:scheduled` | Every 30 min via Scheduler | `%{time_of_day: "morning"}` |
| `:price_spike` | Price change > threshold (default 10%) | `%{token: key, change: float}` |
| `:price_drop` | Significant drop (same threshold check, negative) | `%{token: key, change: float}` |
| `:mention_reply` | High-engagement mention (score > 10) or question | `%{mentions: list}` |
| `:weird_market` | Unusual Polymarket content | `%{markets: list}` |
| `:volume_surge` | Unusual trading volume | any |
| `:manual` | Manual request | `%{immediate: true}` |

When `context[:immediate]` is true, the event is processed synchronously before returning. Otherwise it is queued in `state.pending`.

### Vibes

The `PromptBuilder` supports multiple commentary styles (selected randomly):

- `:crypto_commentary` - Market analysis, roast ETH gas, Base commentary
- `:gaming_joke` - Retro gaming references, speedrun metaphors
- `:agent_self_aware` - BEAM runtime, memory files, Python comparisons
- `:lemon_persona` - Uses `commentary_lemon_persona_instructions` and `developer_alias` from config

### Usage

```elixir
# Trigger commentary manually (immediate)
MarketIntel.Commentary.Pipeline.trigger(:manual, %{immediate: true})

# Convenience wrapper for the above
MarketIntel.Commentary.Pipeline.generate_now()

# Trigger with context (queued)
MarketIntel.Commentary.Pipeline.trigger(:price_spike, %{token: :tracked_token, change: 15.0})

# Check pipeline state
:sys.get_state(MarketIntel.Commentary.Pipeline)
```

### PromptBuilder

`MarketIntel.Commentary.PromptBuilder` is a struct-based module. Build a prompt like this:

```elixir
builder = %MarketIntel.Commentary.PromptBuilder{
  vibe: :crypto_commentary,
  market_data: %{
    token: {:ok, %{price_usd: "1.23", price_change_24h: 5.5}},
    eth: {:ok, %{price_usd: 3500.0}},
    polymarket: {:ok, %{trending: ["event1"]}}
  },
  token_name: "ZEEBOT",
  token_ticker: "$ZEEBOT",
  trigger_type: :scheduled,
  trigger_context: %{}
}

prompt = MarketIntel.Commentary.PromptBuilder.build(builder)
```

## Caching Strategy

**Two-tier approach:**

### Hot Cache (ETS)

- Module: `MarketIntel.Cache`
- TTL: 5 minutes default; pass explicit TTL as third arg to `put/3`
- ETS table: `:market_intel_cache` (public, named, concurrent reads/writes)
- Cleanup: runs every 1 minute to delete expired entries

Cache keys used in practice:

| Key | Set by | Content |
|-----|--------|---------|
| `:tracked_token_price` | DexScreener | Token price map |
| `:eth_price` (via config signal key) | DexScreener | ETH price map |
| `:base_activity` | Cache.get_snapshot | Alias for base ecosystem data |
| `:base_ecosystem` | DexScreener | Top 10 Base tokens by volume |
| `:base_network_stats` | OnChain | Gas price, congestion |
| `:tracked_token_transfers` | OnChain | Recent + large transfers |
| `:tracked_token_large_transfers` | OnChain | Large transfers only |
| `:polymarket_trending` | Polymarket | Categorized markets |
| `:recent_mentions` | TwitterMentions | Analyzed mentions list |
| `:mention_sentiment` | TwitterMentions | Sentiment summary |
| `:holder_stats` | OnChain | Holder stats (stub, always unknown) |

Note: The cache keys for tracked token data are configurable via `MarketIntel.Config` (e.g. `tracked_token_price_cache_key/0`). Do not hardcode them.

### Persistent Storage (SQLite)

- Module: `MarketIntel.Repo` (Ecto SQLite3)
- DB path: `../../data/market_intel.db` relative to config dir
- Tables: `price_snapshots`, `mention_events`, `commentary_history`, `market_signals`
- All tables use `:binary_id` primary key and `utc_datetime_usec` timestamps

### Cache Operations

```elixir
# Store with TTL (default 5 min)
MarketIntel.Cache.put(:key, value)
MarketIntel.Cache.put(:key, value, :timer.minutes(10))

# Retrieve — returns {:ok, value}, :expired, or :not_found
{:ok, value} = MarketIntel.Cache.get(:key)

# Get full snapshot for commentary generation
# Returns %{token: ..., eth: ..., base: ..., polymarket: ..., mentions: ..., timestamp: ...}
snapshot = MarketIntel.Cache.get_snapshot()
```

## Scheduling

The `MarketIntel.Scheduler` GenServer handles periodic commentary triggers:

| Task | Interval | Action |
|------|----------|--------|
| Regular commentary | 30 min | `Pipeline.trigger(:scheduled, %{time_of_day: "morning"})` |
| Deep analysis | 2 hours | `handle_info(:deep_analysis, ...)` — currently a no-op stub |

Data sources schedule themselves via `HttpClient.schedule_next_fetch/3` which wraps `Process.send_after/3`.

## HttpClient

All ingestion modules use `MarketIntel.Ingestion.HttpClient` for HTTP requests:

```elixir
# GET request
{:ok, parsed_map} = HttpClient.get(url, headers, source: "MySource")

# POST request (e.g. GraphQL)
{:ok, parsed_map} = HttpClient.post(url, json_body, headers, source: "MySource")

# Add auth header only if secret is configured
headers = HttpClient.maybe_add_auth_header([], :dexscreener_key, "Bearer")

# Schedule next fetch
HttpClient.schedule_next_fetch(self(), :fetch, :timer.minutes(5))
```

The underlying HTTP module is injectable for tests:

```elixir
# config/test.exs
config :market_intel, http_client_module: HTTPoison.Mock
config :market_intel, http_client_secrets_module: MarketIntel.Secrets.Mock
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
# Fetch all sources immediately (cast-based, async)
MarketIntel.Ingestion.DexScreener.fetch()
MarketIntel.Ingestion.Polymarket.fetch()
MarketIntel.Ingestion.OnChain.fetch()
# TwitterMentions has no public fetch/0 — it only schedules internally
```

### Check Current Data

```elixir
# Get cached tracked token price
MarketIntel.Ingestion.DexScreener.get_tracked_token_data()
# => {:ok, %{price_usd: "1.23", price_change_24h: 5.5, ...}} | :not_found | :expired

# Get Polymarket data
MarketIntel.Ingestion.Polymarket.get_trending()
# => {:ok, %{trending: [...], crypto_related: [...], ai_agent: [...], weird_niche: [...], high_volume: [...]}}

# Get on-chain stats
MarketIntel.Ingestion.OnChain.get_network_stats()
MarketIntel.Ingestion.OnChain.get_large_transfers()

# Get Twitter mention data
MarketIntel.Ingestion.TwitterMentions.get_recent_mentions()
MarketIntel.Ingestion.TwitterMentions.get_sentiment_summary()
```

### Configuration

```elixir
# Tracked token config (set in config.exs under :tracked_token key)
MarketIntel.Config.tracked_token_name()       # "ZEEBOT"
MarketIntel.Config.tracked_token_symbol()     # "ZEEBOT"
MarketIntel.Config.tracked_token_ticker()     # "$ZEEBOT"
MarketIntel.Config.tracked_token_address()    # "0x14d2..."
MarketIntel.Config.tracked_token_price_cache_key()          # :tracked_token_price
MarketIntel.Config.tracked_token_signal_key()               # :tracked_token
MarketIntel.Config.tracked_token_transfers_cache_key()      # :tracked_token_transfers
MarketIntel.Config.tracked_token_large_transfers_cache_key() # :tracked_token_large_transfers
MarketIntel.Config.tracked_token_price_change_signal_threshold_pct() # 10
MarketIntel.Config.tracked_token_large_transfer_threshold_base_units() # 1_000_000_000_000_000_000_000_000

# Commentary persona config
MarketIntel.Config.commentary_handle()    # "@realzeebot"
MarketIntel.Config.commentary_voice()     # "witty, technical, ..."
MarketIntel.Config.commentary_developer_alias()  # "z80"

# X account
MarketIntel.Config.x_account_id()
MarketIntel.Config.x_account_handle()
```

### Secrets Management

Secrets resolve from `LemonCore.Secrets` store first, then fall back to environment variables.

Known secret atoms and their env var names:

| Atom | Env Var |
|------|---------|
| `:basescan_key` | `MARKET_INTEL_BASESCAN_KEY` |
| `:dexscreener_key` | `MARKET_INTEL_DEXSCREENER_KEY` |
| `:openai_key` | `MARKET_INTEL_OPENAI_KEY` |
| `:anthropic_key` | `MARKET_INTEL_ANTHROPIC_KEY` |
| `:x_client_id` | `X_API_CLIENT_ID` |
| `:x_client_secret` | `X_API_CLIENT_SECRET` |
| `:x_access_token` | `X_API_ACCESS_TOKEN` |
| `:x_refresh_token` | `X_API_REFRESH_TOKEN` |

```elixir
# Check if secret is configured
MarketIntel.Secrets.configured?(:basescan_key)  # => true | false

# Get secret value
{:ok, key} = MarketIntel.Secrets.get(:basescan_key)
key = MarketIntel.Secrets.get!(:basescan_key)  # raises on missing

# Store a secret
:ok = MarketIntel.Secrets.put(:basescan_key, "abc123")

# View all configured (masked)
MarketIntel.Secrets.all_configured()
```

### Error Handling

All ingestion modules return structured errors. Error types: `:api_error`, `:parse_error`, `:network_error`, `:config_error`.

```elixir
alias MarketIntel.Errors

# Create standardized errors
Errors.api_error("Source", "reason")     # {:error, %{type: :api_error, source: "Source", reason: "reason"}}
Errors.network_error(:timeout)           # {:error, %{type: :network_error, reason: "timeout"}}
Errors.parse_error("invalid JSON")       # {:error, %{type: :parse_error, reason: "invalid JSON"}}
Errors.config_error("missing key")       # {:error, %{type: :config_error, reason: "missing key"}}

# Format for logging
Errors.format_for_log({:error, %{type: :api_error, source: "API", reason: "fail"}})
# => "API error from API: fail"

# Check error type
Errors.type?(error, :api_error)  # => true | false

# Unwrap reason from error tuple
Errors.unwrap({:error, %{type: :api_error, reason: "fail"}})  # => "fail"
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
├── secrets_test.exs
└── trigger_system_test.exs
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

Tests define mocks in `test/test_helper.exs`. There are two mock modules:

- `MarketIntel.Ingestion.HttpClientMock` — for `HttpClient.get/post` calls (used by most ingestion tests)
- `HTTPoison.Mock` — for direct `HTTPoison` calls (used by `OnChain` gas fetching)
- `MarketIntel.Secrets.Mock` — for secrets resolution

Configure via application env in tests:

```elixir
Application.put_env(:market_intel, :http_client_module, MarketIntel.Ingestion.HttpClientMock)
Application.put_env(:market_intel, :http_client_secrets_module, MarketIntel.Secrets.Mock)
```

Example test setup:

```elixir
defmodule MarketIntel.Ingestion.DexScreenerTest do
  use ExUnit.Case, async: false
  import Mox

  setup :verify_on_exit!

  setup do
    unless Process.whereis(MarketIntel.Cache) do
      start_supervised!(MarketIntel.Cache)
    end
    :ok
  end

  test "handles API timeout" do
    expect(MarketIntel.Ingestion.HttpClientMock, :get, fn _url, _headers, _opts ->
      {:error, %{type: :network_error, reason: :timeout}}
    end)

    result = MarketIntel.Ingestion.HttpClientMock.get("https://api.dexscreener.com/test", [], [])
    assert {:error, %{type: :network_error}} = result
  end
end
```

### Test Fixtures

Store API response samples in `test/fixtures/`:
- `dex_screener_token_response.json`
- `dex_screener_ecosystem_response.json`
- `dex_screener_empty_response.json`
- `polymarket_markets_response.json`
- `basescan_transfers_response.json`
- `twitter_mentions_response.json`

### Ecto Testing

```elixir
setup do
  :ok = Ecto.Adapters.SQL.Sandbox.checkout(MarketIntel.Repo)
end

test "price snapshot changeset" do
  attrs = %{token_symbol: "LEM", price_usd: "1.50", source: "dexscreener"}
  changeset = MarketIntel.Schema.PriceSnapshot.changeset(%MarketIntel.Schema.PriceSnapshot{}, attrs)
  assert changeset.valid?
end
```

Schema modules live in `MarketIntel.Schema`:
- `MarketIntel.Schema.PriceSnapshot`
- `MarketIntel.Schema.MentionEvent`
- `MarketIntel.Schema.CommentaryHistory`
- `MarketIntel.Schema.MarketSignal`

### Environment Variables for Testing

```bash
export MARKET_INTEL_BASESCAN_KEY=test_key
export MARKET_INTEL_DEXSCREENER_KEY=test_key
```

---

**Dependencies:** `lemon_core`, `agent_core`, `httpoison`, `jason`, `ecto_sql`, `ecto_sqlite3`, `gen_stage`, `mox` (test only), `lemon_channels` (compile-time only, `runtime: false`)
