# MarketIntel Secrets Guide

## Overview

MarketIntel uses **LemonCore.Secrets** for secure API key storage. This is the same secure storage system used by the rest of the Lemon platform.

## Why Secrets Store?

- **Encrypted**: API keys are stored encrypted at rest
- **Persistent**: Survives application restarts
- **Integrated**: Works with Lemon's existing secret management
- **Secure**: Keys are never logged in full (always masked)
- **Flexible**: Can be set via CLI, code, or environment fallback

## Available Secrets

### MarketIntel-Specific

| Secret Name | Purpose | Fallback Env Var |
|-------------|---------|------------------|
| `basescan_key` | BaseScan API for on-chain data | `MARKET_INTEL_BASESCAN_KEY` |
| `dexscreener_key` | DEX Screener API (optional) | `MARKET_INTEL_DEXSCREENER_KEY` |
| `openai_key` | OpenAI API for AI commentary | `MARKET_INTEL_OPENAI_KEY` |
| `anthropic_key` | Anthropic API for AI commentary | `MARKET_INTEL_ANTHROPIC_KEY` |

### Shared with Lemon

| Secret Name | Purpose | Managed By |
|-------------|---------|------------|
| `X_API_CLIENT_ID` | X API OAuth 2.0 | `lemon_channels` |
| `X_API_CLIENT_SECRET` | X API OAuth 2.0 | `lemon_channels` |
| `X_API_ACCESS_TOKEN` | X API OAuth 2.0 | `lemon_channels` |
| `X_API_REFRESH_TOKEN` | X API OAuth 2.0 | `lemon_channels` |

## CLI Usage

### Check Configuration

```bash
cd ~/dev/lemon/apps/market_intel
elixir scripts/secrets.exs check
```

Output:
```
🔍 Checking MarketIntel Secrets

==================================================

Data Source APIs:
  ✅ BaseScan API (on-chain data)
  ❌ DEX Screener API (optional)

AI Generation:
  ✅ OpenAI API
  ❌ Anthropic API (alternative)

X API (from lemon_channels):
  ℹ️  X API keys are managed by lemon_channels
     Check: LemonChannels.Adapters.XAPI.configured?()

==================================================
✅ AI commentary generation available
```

### List All Secrets

```bash
elixir scripts/secrets.exs list
```

### Get a Secret (Masked)

```bash
elixir scripts/secrets.exs get basescan_key
# Output: abcd...wxyz
```

### Set a Secret

```bash
elixir scripts/secrets.exs set basescan_key "your_api_key"
```

## Programmatic Usage

### Check if Configured

```elixir
MarketIntel.Secrets.configured?(:basescan_key)
# => true or false
```

### Get a Secret

```elixir
{:ok, key} = MarketIntel.Secrets.get(:basescan_key)
# => {:ok, "abc123..."}

# Or with raise
key = MarketIntel.Secrets.get!(:basescan_key)
# => "abc123..."
```

### Get All Configured (Masked)

```elixir
MarketIntel.Secrets.all_configured()
# => %{basescan_key: "abcd...wxyz", openai_key: "sk-...1234"}
```

### Set a Secret

```elixir
MarketIntel.Secrets.put(:basescan_key, "new_key")
# => :ok
```

## Priority Order

When resolving secrets, MarketIntel checks in this order:

1. **Secrets Store** (`LemonCore.Secrets`) - Primary
2. **Environment Variables** - Fallback
3. **No Key** - Limited functionality

## Environment Variable Fallback

If you prefer environment variables, set these:

```bash
export MARKET_INTEL_BASESCAN_KEY="your_key"
export MARKET_INTEL_OPENAI_KEY="sk-..."
export MARKET_INTEL_ANTHROPIC_KEY="sk-ant-..."
```

The secrets store will automatically fall back to these if the secret isn't in the store.

## Security

- Secrets are **never logged in full** (only first/last 4 chars shown)
- Secrets are **encrypted at rest** by LemonCore.Secrets
- Secrets **persist across restarts**
- The secrets store is **isolated per Lemon installation**

## Troubleshooting

### "Secret not found"

```bash
# Check if it's configured
elixir scripts/secrets.exs check

# Add it
elixir scripts/secrets.exs set basescan_key "your_key"
```

### "Module not loaded"

Make sure Lemon is running:
```bash
cd ~/dev/lemon
iex -S mix
```

### Fallback to env vars not working

Check the exact env var name:
```bash
echo $MARKET_INTEL_BASESCAN_KEY
```

## Integration with X API

The X API credentials are managed by `lemon_channels` and use the same secrets store. MarketIntel doesn't need to configure them separately - it uses the existing X API client.

To check X API configuration:
```elixir
LemonChannels.Adapters.XAPI.configured?
```

## Next Steps

1. Run `elixir scripts/secrets.exs check` to see current state
2. Add any missing secrets with `elixir scripts/secrets.exs set`
3. Test with `MarketIntel.Secrets.configured?(:basescan_key)`
4. Start ingesting data!
