# MarketIntel App

Market data ingestion and AI commentary generation for the Lemon platform.

## Quick Orientation

MarketIntel is an OTP application in the Lemon umbrella that:

1. **Ingests market data** from DEX Screener, Polymarket, BaseScan, and Twitter/X using supervised GenServer workers on fixed polling intervals
2. **Caches hot data** in an ETS table with per-entry TTL (5 min default)
3. **Persists time-series data** in SQLite via Ecto (partially stubbed)
4. **Detects market signals** via threshold checks (price spikes, large transfers, unusual markets)
5. **Generates AI commentary** tweets through a GenStage pipeline using OpenAI or Anthropic
6. **Posts to X/Twitter** via `LemonChannels` (dynamic module loading, `runtime: false` dep)

The app runs under a `one_for_one` supervisor. Core infrastructure (Cache, Repo) always starts. Ingestion workers, commentary pipeline, and scheduler are gated by feature flags in `:market_intel, :ingestion` config.

## Key Files and Purposes

### Entry Points

- `lib/market_intel/application.ex` -- Supervision tree. `core_children/0` (always) + `optional_ingestors/0` (feature-gated). Start here to understand what runs.
- `lib/market_intel/config.ex` -- All configuration with sensible defaults. Tracked token settings, X account, commentary persona. Uses `Application.get_env/3` with keyword normalization and legacy backfill.

### Ingestion Layer

- `lib/market_intel/ingestion/dex_screener.ex` -- GenServer polling DEX Screener REST API every 2 min. Fetches tracked token + ETH + Base ecosystem. Triggers `:price_spike` when change exceeds threshold.
- `lib/market_intel/ingestion/polymarket.ex` -- GenServer polling Polymarket GraphQL every 5 min. Categorizes markets (crypto, AI, weird, high-volume). Triggers `:weird_market`.
- `lib/market_intel/ingestion/twitter_mentions.ex` -- GenServer for X mentions every 2 min. **Fetch is a stub** (returns `[]`). Sentiment analysis and engagement scoring are implemented.
- `lib/market_intel/ingestion/on_chain.ex` -- GenServer for Base network data every 3 min. Gas prices via Base RPC, transfers via BaseScan API. Large transfer detection with configurable threshold.
- `lib/market_intel/ingestion/http_client.ex` -- Shared HTTP helper. GET/POST with JSON parsing, error wrapping, auth header injection. Injectable via `:http_client_module` app env for testing.

### Commentary Layer

- `lib/market_intel/commentary/pipeline.ex` -- GenStage `producer_consumer`. Entry point: `trigger/2` or `generate_now/0`. Builds prompt via PromptBuilder, generates text via `AgentCore.TextGeneration.complete_text/4`, posts via `LemonChannels.Adapters.XAPI.Client.post_text/1` (dynamic), stores in SQLite.
- `lib/market_intel/commentary/prompt_builder.ex` -- Struct-based prompt builder. Assembles: base prompt (persona/voice) + market context (formatted data) + vibe instructions (style) + trigger context (event-specific) + rules (280 char limit, etc).

### Infrastructure

- `lib/market_intel/cache.ex` -- GenServer owning ETS table `:market_intel_cache`. TTL-based expiry. `get_snapshot/0` aggregates all market data for commentary.
- `lib/market_intel/repo.ex` -- Ecto Repo with SQLite3 adapter.
- `lib/market_intel/schema.ex` -- Four schemas in one file: `PriceSnapshot`, `MentionEvent`, `CommentaryHistory` (has changeset with upsert support), `MarketSignal`. All use `:binary_id` PKs and `utc_datetime_usec` timestamps.
- `lib/market_intel/secrets.ex` -- Resolves secrets from `LemonCore.Secrets` store first, then env vars. Maps atom keys to env var names. Supports `get/1`, `get!/1`, `configured?/1`, `put/2`, `all_configured/0`.
- `lib/market_intel/errors.ex` -- Four error types: `:api_error`, `:config_error`, `:parse_error`, `:network_error`. Each returns `{:error, %{type: atom, ...}}`. Includes `format_for_log/1`, `type?/2`, `unwrap/1`.
- `lib/market_intel/scheduler.ex` -- Triggers `:scheduled` commentary every 30 min and `:deep_analysis` every 2 hours (deep analysis is a no-op stub).

## Architecture Boundary

`market_intel` depends on `agent_core` for AI text generation but must NOT depend on the `ai` app directly. All LLM completion calls go through `AgentCore.TextGeneration.complete_text/4`. The `lemon_channels` dependency is `runtime: false` (compile-time only); X API posting uses `Code.ensure_loaded?` + `apply/3` for dynamic dispatch.

## How to Add a New Data Source

1. **Create the worker module** in `lib/market_intel/ingestion/new_source.ex`:

```elixir
defmodule MarketIntel.Ingestion.NewSource do
  use GenServer
  require Logger

  alias MarketIntel.Ingestion.HttpClient
  alias MarketIntel.Errors

  @source_name "NewSource"
  @fetch_interval :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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

  @impl true
  def handle_cast(:fetch, state) do
    do_fetch()
    {:noreply, %{state | last_fetch: DateTime.utc_now()}}
  end

  defp do_fetch do
    HttpClient.log_info(@source_name, "fetching...")

    case HttpClient.get("https://api.example.com/data", [], source: @source_name) do
      {:ok, data} ->
        parsed = parse_data(data)
        MarketIntel.Cache.put(:new_source_data, parsed)
        check_signals(parsed)

      {:error, _} = error ->
        HttpClient.log_error(@source_name, Errors.format_for_log(error))
    end
  end

  defp parse_data(data), do: data
  defp check_signals(_data), do: :ok

  defp schedule_next do
    HttpClient.schedule_next_fetch(self(), :fetch, @fetch_interval)
  end
end
```

2. **Add feature flag** to `config/config.exs`:

```elixir
config :market_intel, :ingestion, %{
  # ... existing flags
  enable_new_source: true
}
```

3. **Register in supervision tree** in `lib/market_intel/application.ex`:

```elixir
defp optional_ingestors do
  config = Application.get_env(:market_intel, :ingestion, %{})

  []
  # ... existing workers
  |> maybe_add(config[:enable_new_source], MarketIntel.Ingestion.NewSource)
  # ...
end
```

4. **Add secrets** if needed in `lib/market_intel/secrets.ex`:

```elixir
@secret_names %{
  # ... existing secrets
  new_source_key: "MARKET_INTEL_NEW_SOURCE_KEY"
}
```

5. **Add to cache snapshot** if the data should be available for commentary (in `cache.ex` `get_snapshot/0`).

6. **Write tests** in `test/market_intel/ingestion/new_source_test.exs`. Use Mox for HTTP mocking:

```elixir
defmodule MarketIntel.Ingestion.NewSourceTest do
  use ExUnit.Case, async: false
  import Mox

  setup :verify_on_exit!

  setup do
    unless Process.whereis(MarketIntel.Cache) do
      start_supervised!(MarketIntel.Cache)
    end
    :ok
  end

  test "fetches and caches data" do
    expect(MarketIntel.Ingestion.HttpClientMock, :get, fn _url, _headers, _opts ->
      {:ok, %{"data" => "test"}}
    end)
    # ...
  end
end
```

7. **Add test fixtures** in `test/fixtures/new_source_response.json`.

## Commentary Pipeline Details

### Trigger Flow

```
DexScreener.check_price_signals/1  --->  Pipeline.trigger(:price_spike, ctx)
Polymarket.check_market_events/1   --->  Pipeline.trigger(:weird_market, ctx)
TwitterMentions.check_reply_opps/1 --->  Pipeline.trigger(:mention_reply, ctx)
Scheduler (30 min)                 --->  Pipeline.trigger(:scheduled, ctx)
Manual                             --->  Pipeline.generate_now()
```

### Processing

1. `handle_cast({:trigger, type, context}, state)` -- queues event or processes immediately if `context[:immediate]`
2. `process_commentary/1` -- gets cache snapshot, builds prompt, calls AI, posts tweet, stores history
3. AI provider selection: OpenAI (if key configured) > Anthropic (if key configured) > fallback templates
4. Tweet truncation: 280 char max, adds "..." if truncated
5. X posting: dynamic `apply(LemonChannels.Adapters.XAPI.Client, :post_text, [text])`
6. Storage: `CommentaryHistory` schema with upsert on `tweet_id`

### PromptBuilder Structure

The `PromptBuilder` is a struct with fields: `vibe`, `market_data`, `token_name`, `token_ticker`, `trigger_type`, `trigger_context`. The `build/1` function assembles five sections:

1. **Base prompt**: Persona handle and voice from config
2. **Market context**: Formatted token/ETH/Polymarket data (handles `:error`, `:expired`, `:not_found`)
3. **Vibe instructions**: Style-specific directions (4 vibes: `:crypto_commentary`, `:gaming_joke`, `:agent_self_aware`, `:lemon_persona`)
4. **Trigger context**: Event-specific instructions (e.g. "pumped 15.5%", "weird Polymarket trending")
5. **Rules**: Output constraints (280 chars, no @mentions, be witty)

## Configuration Reference

All configuration lives under the `:market_intel` OTP app key. `MarketIntel.Config` provides accessor functions with defaults.

### Key Config Namespaces

| Config Key | Accessor Module | Purpose |
|-----------|-----------------|---------|
| `:ingestion` | `Application` (direct) | Feature flags for workers |
| `:tracked_token` | `Config.tracked_token*` | Token to track (name, symbol, address, thresholds, cache keys) |
| `:x` | `Config.x*` | X/Twitter account (ID, handle) |
| `:commentary_persona` | `Config.commentary_*` | Commentary voice, handle, persona instructions |
| `:eth_address` | `Config.eth_address/0` | ETH contract address on Base |
| `:holder_stats_enabled` | Direct `Application.get_env` | Gate for on-chain holder stats |
| `:http_client_module` | Used by `HttpClient` | Injectable HTTP module (default: `HTTPoison`) |
| `:http_client_secrets_module` | Used by `HttpClient` | Injectable secrets module |
| `:use_secrets` | Used by `Secrets` | Toggle LemonCore.Secrets store |
| `:secrets_module` | Used by `Secrets` | Secrets store module (default: `LemonCore.Secrets`) |

### Config Defaults

Tracked token defaults: name `"Tracked Token"`, symbol `"TOKEN"`, address `nil`, signal threshold `10%`, large transfer threshold `1e24` base units.

Commentary persona defaults: handle `"@marketintel"`, voice `"witty, technical, crypto-native, occasionally self-deprecating"`, developer alias `nil`.

ETH address default: `"0x4200000000000000000000000000000000000006"` (Base WETH).

## Testing Guidance

### Running Tests

```bash
# All market_intel tests
mix test apps/market_intel

# Specific file
mix test apps/market_intel/test/market_intel/ingestion/dex_screener_test.exs

# With coverage
mix test apps/market_intel --cover
```

### Test Infrastructure

**Mox definitions** in `test/test_helper.exs`:

- `MarketIntel.Ingestion.HttpClientMock` -- mock for `HttpClient.get/post` calls
- `HTTPoison.Mock` -- mock for direct `HTTPoison` calls (used by `OnChain` gas fetching)
- `MarketIntel.Secrets.Mock` -- mock for secrets resolution

**Behaviours** defined in `test/test_helper.exs`:

- `MarketIntel.Ingestion.HttpClientBehaviour` -- `get/3`, `post/4`
- `MarketIntel.Ingestion.SecretsBehaviour` -- `get/1`

**Test configuration** (set in individual tests or `test.exs`):

```elixir
Application.put_env(:market_intel, :http_client_module, MarketIntel.Ingestion.HttpClientMock)
Application.put_env(:market_intel, :http_client_secrets_module, MarketIntel.Secrets.Mock)
```

### Common Test Patterns

**Cache setup** (most tests need this):

```elixir
setup do
  unless Process.whereis(MarketIntel.Cache) do
    start_supervised!(MarketIntel.Cache)
  end
  :ok
end
```

**ETS cleanup between tests**:

```elixir
setup do
  :ets.delete_all_objects(:market_intel_cache)
  :ok
end
```

**Config isolation** (for config tests):

```elixir
setup do
  original = Application.get_all_env(:market_intel)
  on_exit(fn ->
    for {key, _} <- Application.get_all_env(:market_intel),
        do: Application.delete_env(:market_intel, key)
    for {key, val} <- original,
        do: Application.put_env(:market_intel, key, val)
  end)
  :ok
end
```

**Secrets testing** (disable store, test env fallback):

```elixir
setup do
  Application.put_env(:market_intel, :use_secrets, false)
  # Set/delete env vars as needed
  on_exit(fn -> System.delete_env("MARKET_INTEL_BASESCAN_KEY") end)
  :ok
end
```

### Test Files

| Test File | Covers | Notes |
|-----------|--------|-------|
| `cache_test.exs` | Cache put/get, TTL, expiry, cleanup, snapshot | Needs Cache GenServer |
| `config_test.exs` | All Config accessors, defaults, normalization | Saves/restores app env |
| `errors_test.exs` | All error constructors, formatting, type checking | Pure functions, `async: true` safe |
| `secrets_test.exs` | Secret resolution, env fallback, masking | Disables secrets store, manages env vars |
| `scheduler_test.exs` | Scheduler intervals | May need Pipeline running |
| `schema_test.exs` | Ecto schema changesets | May need Repo for insert tests |
| `trigger_system_test.exs` | Threshold logic, volume surge, market events, mention detection, cooldowns | Pure logic, `async: true` safe |
| `ingestion/dex_screener_test.exs` | DexScreener GenServer, parsing, price signals, cache integration | Uses fixtures, Mox |
| `ingestion/polymarket_test.exs` | Polymarket market categorization | Uses fixtures, Mox |
| `ingestion/on_chain_test.exs` | OnChain transfers, holder stats | Uses Mox |
| `ingestion/twitter_mentions_test.exs` | Mention analysis, sentiment, engagement | Stub fetch |
| `ingestion/http_client_test.exs` | HTTP request handling, JSON parsing, error wrapping | Uses Mox |
| `commentary/pipeline_test.exs` | Pipeline triggers, vibes, AI integration, snapshot formatting, history storage | Needs Cache + Pipeline GenServers |
| `commentary/prompt_builder_test.exs` | Prompt construction for all vibes/triggers/data states | Pure functions, `async: true` safe |
| `commentary/commentary_history_db_test.exs` | Commentary history DB operations | May need Repo |

### Test Fixtures

Located in `test/fixtures/`:

- `dex_screener_token_response.json` -- Multi-pair token response with liquidity data
- `dex_screener_ecosystem_response.json` -- Base ecosystem search response
- `dex_screener_empty_response.json` -- Empty pairs response
- `polymarket_markets_response.json` -- GraphQL markets response
- `basescan_transfers_response.json` -- Token transfer history
- `twitter_mentions_response.json` -- Mention data with engagement metrics

## Implementation Status (Stubs)

These are known stubs tracked in `planning/plans/PLN-20260222-debt-phase-10-monolith-footprint-reduction.md` (M1):

| Stub | Location | Current Behavior |
|------|----------|-----------------|
| Twitter fetch | `TwitterMentions.fetch_mentions/1` | Returns `[]` |
| DB persistence (DexScreener) | `DexScreener.persist_to_db/2` | Returns `:ok` (no-op) |
| Deep analysis | `Scheduler.handle_info(:deep_analysis, ...)` | Logs and reschedules (no-op) |
| Gas price parsing | `OnChain.parse_gas_price/1` | Returns hardcoded `0.1` |
| Block tracking | `OnChain.fetch_latest_block/0` | Returns `0` |
| Holder stats | `OnChain.fetch_holder_stats/0` | Returns `:not_enabled` when gated off |

## Connections to Other Apps

| App | Relationship | Details |
|-----|-------------|---------|
| `lemon_core` | Runtime dependency | `LemonCore.Secrets` for secret storage and resolution |
| `agent_core` | Runtime dependency | `AgentCore.TextGeneration.complete_text/4` for AI-generated commentary |
| `lemon_channels` | Compile-time only (`runtime: false`) | `LemonChannels.Adapters.XAPI.Client.post_text/1` for posting tweets; loaded dynamically via `Code.ensure_loaded?` |

## Common Tasks

### Disable all ingestion (e.g. for dev/test)

Set all feature flags to `false` in config. Core infrastructure still starts.

### Change tracked token

Update `:market_intel, :tracked_token` config with new `name`, `symbol`, `address`. Optionally customize `signal_key`, `price_cache_key`, and thresholds.

### Change commentary voice

Update `:market_intel, :commentary_persona` with new `voice` string and/or `lemon_persona_instructions`.

### Add a new commentary vibe

1. Add atom to `@vibes` list in `Commentary.Pipeline`
2. Add corresponding `case` clause in `PromptBuilder.build_vibe_instructions/1`
3. Add type to `@type vibe` in both `Pipeline` and `PromptBuilder`

### Add a new trigger type

1. Add atom to `@triggers` map in `Commentary.Pipeline`
2. Add `case` clause in `PromptBuilder.build_trigger_context/1`
3. Add type to `@type trigger_type` in both `Pipeline` and `PromptBuilder`
4. Fire it from the appropriate ingestion worker using `Commentary.Pipeline.trigger/2`

### Debug cache state

```elixir
# List all ETS entries
:ets.tab2list(:market_intel_cache)

# Check specific key
MarketIntel.Cache.get(:tracked_token_price)

# Get full snapshot
MarketIntel.Cache.get_snapshot()
```

### Debug worker state

```elixir
:sys.get_state(MarketIntel.Ingestion.DexScreener)
:sys.get_state(MarketIntel.Commentary.Pipeline)
:sys.get_state(MarketIntel.Scheduler)
```
