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

### 4. ElevenLabs MP3 / iodata detection
**Files:** `apps/lemon_gateway/lib/lemon_gateway/voice/call_session.ex`, `apps/lemon_gateway/lib/lemon_gateway/voice/audio_conversion.ex`

**Problem:** ElevenLabs sometimes returned MP3 data with an `ID3` tag as iodata. `CallSession.convert_pcm_to_mulaw/1` passed the list straight to `AudioConversion.mp3_data?/1`/`pcm16_to_mulaw/1`, which only accepted binaries and crashed with `FunctionClauseError` during playback.

**Fix:** Normalize every ElevenLabs payload to a binary before detection/encoding and teach `mp3_data?/1` to accept iodata plus ID3 headers so the warning log fires before mu-law conversion.

### 5. Twilio voice session lifecycle + call metadata alignment
**Files:** `apps/lemon_gateway/lib/lemon_gateway/voice/call_session.ex`, `apps/lemon_gateway/lib/lemon_gateway/voice/twilio_websocket.ex`, `apps/lemon_gateway/lib/lemon_gateway/voice/webhook_router.ex`

**Problem:** Voice call sessions were restarting after normal termination because `CallSession` used default `:permanent` restart behavior under `DynamicSupervisor`. Also, stream WebSocket sessions started with generated/unknown call metadata when Twilio did not provide query params, causing mismatched `CallSid` values and `"unknown"` phone numbers in logs. Inbound media frames bypassed `CallSession`, so `last_activity_at` was never refreshed and calls timed out as inactive.

**Fix:** Set `CallSession` to `restart: :temporary`, include `CallSid`/`From`/`To` in TwiML stream URL query params, and route inbound media through `CallSession.handle_audio/2` (which updates activity and forwards to Deepgram) instead of bypassing session state.

### 6. ElevenLabs Twilio-native output format
**Files:** `apps/lemon_gateway/lib/lemon_gateway/voice/config.ex`, `apps/lemon_gateway/lib/lemon_gateway/voice/call_session.ex`

**Problem:** Even after iodata handling, ElevenLabs could still return MP3 by default, which is not directly playable in Twilio Media Streams and generated warning logs.

**Fix:** Added `elevenlabs_output_format` config (default `ulaw_8000`), pass it to ElevenLabs `text-to-speech/.../stream` via `output_format` query param, and bypass conversion when format is already `ulaw_8000`.

### 7. Unknown Call SID registry collisions on WebSocket init
**Files:** `apps/lemon_gateway/lib/lemon_gateway/voice/webhook_router.ex`, `apps/lemon_gateway/lib/lemon_gateway/voice/twilio_websocket.ex`

**Problem:** Some Twilio Media Stream connections arrived without query params, so `call_sid` defaulted to `"unknown"`. Subsequent calls reused the same registry key and `TwilioWebSocket.init/1` crashed with `{:error, {:already_started, pid}}`, causing immediate call failures.

**Fix:** Generate a unique temporary call SID when stream metadata is missing and make `TwilioWebSocket.init/1` tolerant of `{:already_started, pid}` by reusing the existing child instead of crashing.

### 8. Speech queue could stall waiting on mark timing
**Files:** `apps/lemon_gateway/lib/lemon_gateway/voice/call_session.ex`

**Problem:** `CallSession` relied on asynchronous `:speech_complete` events to clear `is_speaking`, but welcome/response audio can be synthesized before Twilio stream wiring is fully ready. In those cases, audio may be dropped and the session could remain stuck in speaking state, preventing queued responses from playing.

**Fix:** After each `{:audio_ready, ...}` event, always enqueue local `:speech_complete` to advance the speech state machine even if Twilio mark callbacks are delayed/missing.

### 9. Voice LLM fallback hid API key/config failures
**Files:** `apps/lemon_gateway/lib/lemon_gateway/ai.ex`, `apps/lemon_gateway/lib/lemon_gateway/voice/call_session.ex`

**Problem:** Voice responses always fell back to `"I'm sorry, I didn't catch that..."` whenever `LemonGateway.AI.chat_completion/3` returned an error. At runtime, OpenAI keys stored in Lemon secrets under uppercase names (e.g. `OPENAI_API_KEY`) were not being resolved by `LemonGateway.AI`, so every LLM call failed as missing key and was silently masked.

**Fix:** `LemonGateway.AI` now resolves API keys from env, app config, and Lemon secrets (both lowercase and uppercase key names). `CallSession.generate_llm_response/1` now logs explicit LLM error reasons and returns clearer spoken fallback messages for missing-key vs transient failures.

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
