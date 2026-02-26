# MarketIntel Setup Guide

## Overview

MarketIntel uses **LemonCore.Secrets** for secure API key storage. This is the same secrets store used by the rest of the Lemon platform.

## Secrets vs Environment Variables

- **Secrets Store** (Recommended): Encrypted, persisted, integrated with Lemon
- **Environment Variables** (Fallback): Set via `export`, good for initial setup

## Required Secrets

### X (Twitter) API

These are shared with `lemon_channels` and should already be configured:

| Secret | Purpose | Status |
|--------|---------|--------|
| `X_API_CLIENT_ID` | OAuth 2.0 Client ID | Required |
| `X_API_CLIENT_SECRET` | OAuth 2.0 Client Secret | Required |
| `X_API_ACCESS_TOKEN` | OAuth 2.0 Access Token | Required |
| `X_API_REFRESH_TOKEN` | OAuth 2.0 Refresh Token | Required |

Check if configured:
```bash
cd ~/dev/lemon
iex -S mix

iex> LemonChannels.Adapters.XAPI.configured?
```

### MarketIntel-Specific Secrets

| Secret | Purpose | Required? |
|--------|---------|-----------|
| `basescan_key` | BaseScan API for on-chain data | Recommended |
| `dexscreener_key` | DEX Screener API (optional) | No |
| `openai_key` | OpenAI for AI commentary | No |
| `anthropic_key` | Anthropic for AI commentary | No |

## Quick Setup

### 1. Check Current Secrets

```bash
cd ~/dev/lemon/apps/market_intel

# Check which secrets are configured
elixir scripts/secrets.exs check
```

### 2. Add BaseScan API Key (Recommended)

```bash
# Get a free API key at https://basescan.org/apis
# Free tier: 5 calls/second

# Add to secrets store
elixir scripts/secrets.exs set basescan_key "your_api_key_here"

# Verify
elixir scripts/secrets.exs get basescan_key
```

### 3. Add AI Provider (Optional)

For AI-generated commentary instead of templates:

```bash
# Option 1: OpenAI
elixir scripts/secrets.exs set openai_key "sk-..."

# Option 2: Anthropic
elixir scripts/secrets.exs set anthropic_key "sk-ant-..."
```

### 4. Run Full Setup

```bash
elixir scripts/setup.exs
```

This will:
- Verify secrets are configured
- Create the data directory
- Set up the SQLite database
- Provide next steps

## Managing Secrets

### List All Secrets

```bash
elixir scripts/secrets.exs list
```

Output:
```
🔐 MarketIntel Secrets

==================================================

Configured secrets:
  basescan_key: abcd...wxyz
  openai_key: sk-...1234

Available secrets:
  ✅ basescan_key
  ✅ dexscreener_key
  ❌ openai_key
  ❌ anthropic_key
```

### Check Configuration

```bash
elixir scripts/secrets.exs check
```

### Get a Secret (Masked)

```bash
elixir scripts/secrets.exs get basescan_key
# Output: abcd...wxyz
```

### Set a Secret

```bash
elixir scripts/secrets.exs set basescan_key "new_key"
```

## Using Environment Variables (Fallback)

If you prefer environment variables, MarketIntel will fall back to these:

```bash
export MARKET_INTEL_BASESCAN_KEY="your_key"
export MARKET_INTEL_OPENAI_KEY="sk-..."
export MARKET_INTEL_ANTHROPIC_KEY="sk-ant-..."
```

The priority is:
1. Secrets store (LemonCore.Secrets)
2. Environment variables (fallback)
3. No API key (limited functionality)

## Testing

### Test Secrets Resolution

```elixir
# Check if a secret is configured
MarketIntel.Secrets.configured?(:basescan_key)

# Get a secret
{:ok, key} = MarketIntel.Secrets.get(:basescan_key)

# Get all configured (masked)
MarketIntel.Secrets.all_configured()
```

### Test Data Ingestion

```elixir
# Test DEX Screener (no API key needed)
MarketIntel.Ingestion.DexScreener.fetch()
MarketIntel.Ingestion.DexScreener.get_tracked_token_data()

# Test BaseScan (requires API key)
MarketIntel.Ingestion.OnChain.fetch()
MarketIntel.Ingestion.OnChain.get_network_stats()
```

### Test Commentary

```elixir
# Generate and post a tweet
MarketIntel.Commentary.Pipeline.generate_now()

# Or trigger specific type
MarketIntel.Commentary.Pipeline.trigger(:price_spike, %{change: 15.5})
```

## Troubleshooting

### "Secret not found" errors

- Run `elixir scripts/secrets.exs check` to see what's missing
- Add missing secrets with `elixir scripts/secrets.exs set <name> <value>`
- Or set environment variables as fallback

### "X API not configured"

- X API keys are managed by `lemon_channels`
- Check: `LemonChannels.Adapters.XAPI.configured?`
- Set via environment: `export X_API_CLIENT_ID="..."`

### Database errors

- Ensure `data/` directory exists and is writable
- Run: `mix ecto.create -r MarketIntel.Repo`
- Run: `mix ecto.migrate -r MarketIntel.Repo`

## Security Notes

- Secrets are stored encrypted by LemonCore.Secrets
- Environment variables are only used as fallback
- API keys are never logged in full (always masked)
- The secrets CLI shows only first/last 4 characters
- Secrets persist across Lemon restarts

## Next Steps

1. ✅ Secrets configured
2. ✅ Database created
3. ⏳ Test manual tweet
4. ⏳ Let it run and ingest data
5. ⏳ Watch it post automatically
6. ⏳ Tune commentary prompts
7. ⏳ Add AI generation (if OpenAI/Anthropic key added)
