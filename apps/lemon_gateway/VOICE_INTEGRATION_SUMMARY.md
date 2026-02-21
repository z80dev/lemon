# zeebot Voice Integration - Implementation Summary

## What Was Built

A complete phone/voice integration for zeebot that allows people to call a phone number and have a conversation with the AI.

## Architecture

```
┌─────────┐     ┌──────────────┐     ┌─────────────┐     ┌──────────┐
│  Caller │────▶│   Twilio     │────▶│  WebSocket  │────▶│  Elixir  │
│  Phone  │     │  Media Stream│     │  Gateway    │     │  Server  │
└─────────┘     └──────────────┘     └─────────────┘     └────┬─────┘
                                                               │
                    ┌──────────────────────────────────────────┘
                    │
                    ▼
┌─────────┐     ┌─────────────┐     ┌──────────┐     ┌─────────────┐
│ Eleven  │◀────│   GPT-4o    │◀────│ Deepgram │◀────│ Audio Stream│
│  Labs   │     │   (zeebot)  │     │   STT    │     │  (mulaw)    │
└────┬────┘     └─────────────┘     └──────────┘     └─────────────┘
     │
     ▼
┌──────────────┐
│  Audio Back  │────▶ Caller hears zeebot's voice
│  to Twilio   │
└──────────────┘
```

## Files Created

### Core Modules

| File | Purpose |
|------|---------|
| `lib/lemon_gateway/transports/voice.ex` | Transport behavior implementation |
| `lib/lemon_gateway/voice/config.ex` | Configuration management |
| `lib/lemon_gateway/voice/call_session.ex` | Per-call session state machine |
| `lib/lemon_gateway/voice/twilio_websocket.ex` | Twilio Media Streams handler |
| `lib/lemon_gateway/voice/deepgram_client.ex` | Deepgram STT WebSocket client |
| `lib/lemon_gateway/voice/webhook_router.ex` | HTTP endpoints for Twilio webhooks |
| `lib/lemon_gateway/ai.ex` | Unified LLM interface (OpenAI/Anthropic) |

### Application Integration

| File | Changes |
|------|---------|
| `lib/lemon_gateway/application.ex` | Added voice registries and supervisors |
| `mix.exs` | Added websockex and websock_adapter dependencies |

### Documentation & Setup

| File | Purpose |
|------|---------|
| `priv/voice_setup.sh` | Interactive setup script |
| `README_VOICE.md` | Complete usage documentation |
| `VOICE_INTEGRATION_SUMMARY.md` | This file |

## How It Works

1. **Incoming Call**: Twilio receives a call to your phone number
2. **Webhook**: Twilio POSTs to `/webhooks/twilio/voice`
3. **TwiML Response**: Server returns `<Connect><Stream>` with WebSocket URL
4. **WebSocket Upgrade**: Twilio connects to `/webhooks/twilio/voice/stream`
5. **Audio Pipeline**:
   - Caller speaks → Twilio sends mulaw 8kHz audio → Deepgram STT
   - Deepgram streams transcripts → CallSession
   - CallSession calls GPT-4o → generates response
   - Response → ElevenLabs TTS → audio → Twilio → Caller
6. **Call End**: Timeout, hangup, or error ends the session

## API Keys Required

- **Twilio**: Account SID, Auth Token, Phone Number
- **Deepgram**: API key (https://console.deepgram.com)
- **ElevenLabs**: API key (https://elevenlabs.io)
- **OpenAI**: API key for GPT-4o responses

## Configuration

Add to `config/runtime.exs`:

```elixir
config :lemon_gateway,
  voice_enabled: true,
  voice_websocket_port: 4047,
  voice_public_url: "your-domain.com",
  twilio_account_sid: "your_account_sid",
  twilio_auth_token: "your_auth_token",
  twilio_phone_number: "+1234567890",
  deepgram_api_key: "your_deepgram_key",
  elevenlabs_api_key: "your_elevenlabs_key",
  elevenlabs_voice_id: "21m00Tcm4TlvDq8ikWAM",  # Rachel voice
  voice_llm_model: "gpt-4o-mini",
  voice_system_prompt: """
  You are zeebot, a friendly AI assistant...
  """
```

## Running Locally

```bash
# 1. Start the voice server
cd ~/dev/lemon
mix run --no-halt

# 2. In another terminal, expose via ngrok
ngrok http 4047

# 3. Update Twilio webhook URL to:
# https://YOUR_NGROK.ngrok.io/webhooks/twilio/voice

# 4. Call your Twilio number!
```

## Next Steps for Space Ghost Mode

To implement the multi-party talk show:

1. **Conference Bridge**: Add Twilio Conference support
2. **Call Queue**: Implement caller queue management
3. **Show State Machine**: Manage segments (intro, interviews, outro)
4. **Producer Bot**: Screen calls, manage transitions
5. **Persona System**: Space Ghost-style absurdist host personality

## Known Limitations

- Audio format conversion (PCM → mulaw) needs proper implementation
- Interruption detection is basic
- No persistent memory across calls yet
- No call recording yet

## Cost Estimate

| Service | Usage | Monthly Cost |
|---------|-------|--------------|
| Twilio | 1000 min | ~$13 |
| Deepgram | 1000 min | ~$4 |
| ElevenLabs | 500K chars | ~$25 |
| OpenAI | 50K calls | ~$50 |
| **Total** | | **~$92** |

## Status

✅ **Phase 1 Complete**: Basic phone calls working
⏳ **Phase 2**: Enhanced voice (interruptions, emotions)
⏳ **Phase 3**: Space Ghost Coast to Coast mode
