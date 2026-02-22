# Voice System Fixes Applied

## Issues Fixed

### 1. Deepgram URL Building Error
**File:** `lib/lemon_gateway/voice/deepgram_client.ex`

**Problem:** `URI.encode_www_form/1` was being called with integers (8000, 1) instead of strings.

**Fix:** Changed params to use string values:
```elixir
# Before:
sample_rate: 8000,
channels: 1,

# After:
sample_rate: "8000",
channels: "1",
```

### 2. ElevenLabs TTS Header Error
**File:** `lib/lemon_gateway/voice/call_session.ex`

**Problem:** `:httpc` module expects charlists for headers, not strings.

**Fix:** Convert headers to charlists:
```elixir
# Before:
headers = [
  {"xi-api-key", api_key},
  {"content-type", "application/json"}
]

# After:
headers = [
  {~c"xi-api-key", String.to_charlist(api_key)},
  {~c"content-type", ~c"application/json"}
]
```

### 3. OpenAI/Anthropic API Header Errors
**File:** `lib/lemon_gateway/ai.ex`

**Problem:** Same issue - `:httpc` needs charlists.

**Fix:** Applied same charlist conversion to both OpenAI and Anthropic headers.

## To Apply These Fixes

The code has been compiled. The running BEAM VM needs to reload the modules. Options:

### Option 1: Restart the Gateway (Recommended)
```bash
# In your terminal where the gateway runs:
# Ctrl+C to stop, then restart
```

### Option 2: Hot Reload (If you have IEx access)
```elixir
IEx.Helpers.recompile()
```

## After Restart

1. Voice server will start on port 4047
2. Run the tunnel script:
   ```bash
   cd ~/dev/lemon/apps/lemon_gateway/priv
   ./setup_voice_tunnel.sh
   ```
3. Call +1 (786) 289-9953

## Files Modified

- `apps/lemon_gateway/lib/lemon_gateway/voice/deepgram_client.ex`
- `apps/lemon_gateway/lib/lemon_gateway/voice/call_session.ex`
- `apps/lemon_gateway/lib/lemon_gateway/ai.ex`
- `config/dev.exs` (voice config)
