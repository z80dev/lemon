# zeebot Voice Integration

Make zeebot callable via phone using Twilio Media Streams, Deepgram STT, and ElevenLabs TTS.

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

## Quick Start

### 1. Prerequisites

- Twilio account with a phone number
- Deepgram API key (https://console.deepgram.com)
- ElevenLabs API key (https://elevenlabs.io)
- OpenAI API key (for GPT-4o responses)

### 2. Setup

Run the setup script:

```bash
cd apps/lemon_gateway
./priv/voice_setup.sh
```

Or configure the canonical Lemon TOML file (`~/.lemon/config.toml` or `.lemon/config.toml`):

```toml
[gateway.voice]
enabled = true
websocket_port = 4047
public_url = "https://your-domain.com"
twilio_account_sid_secret = "twilio_account_sid"
twilio_auth_token_secret = "twilio_auth_token"
twilio_phone_number = "+1234567890"
deepgram_api_key_secret = "deepgram_api_key"
elevenlabs_api_key_secret = "elevenlabs_api_key"
elevenlabs_output_format = "ulaw_8000"
```

### 3. Configure Twilio Webhook

In your Twilio console:
1. Go to Phone Numbers → Manage → Active Numbers
2. Click your number
3. Under "Voice & Fax", set:
   - **When a call comes in**: Webhook
   - **URL**: `https://your-domain.com/webhooks/twilio/voice`
   - **Method**: HTTP POST

### 4. Start the Server

```bash
mix run --no-halt
```

For local development with ngrok:

```bash
# Terminal 1: Start the voice server
mix run --no-halt

# Terminal 2: Expose via ngrok
ngrok http 4047

# Then update Twilio webhook to: https://YOUR_NGROK.ngrok.io/webhooks/twilio/voice
```

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `gateway.voice.enabled` | `false` | Enable/disable voice transport |
| `gateway.voice.websocket_port` | `4047` | Port for WebSocket server |
| `gateway.voice.public_url` | `nil` | Public URL for Twilio webhooks |
| `elevenlabs_voice_id` | `"21m00Tcm4TlvDq8ikWAM"` | ElevenLabs voice (Rachel) |
| `elevenlabs_output_format` | `"ulaw_8000"` | ElevenLabs output format (Twilio-compatible) |
| `gateway.voice.llm_model` | `"gpt-4o-mini"` | LLM for responses |
| `gateway.voice.max_call_duration_seconds` | `600` | Max call length (10 min) |
| `gateway.voice.silence_timeout_ms` | `5000` | End call after silence |

## Customizing the Voice

### Change Voice Persona

Edit the system prompt in your Lemon TOML config:

```toml
[gateway.voice]
system_prompt = """
  You are zeebot, the first AI built on the Lemon framework...
  """
```

### Use a Different ElevenLabs Voice

1. Go to https://elevenlabs.io/voice-library
2. Find a voice you like
3. Copy the Voice ID
4. Set in config: `gateway.voice.elevenlabs_voice_id = "your_voice_id"`

### Clone Your Own Voice

1. Record a sample of your voice
2. Upload to ElevenLabs Voice Cloning
3. Use the cloned voice ID in config

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/webhooks/twilio/voice` | POST | Incoming call webhook |
| `/webhooks/twilio/voice/status` | POST | Call status callbacks |
| `/webhooks/twilio/voice/stream` | WebSocket | Media stream (audio) |

## How It Works

1. **Incoming Call**: Twilio receives call, POSTs to webhook
2. **TwiML Response**: Server returns `<Connect><Stream>` to establish WebSocket
3. **Audio Flow**:
   - Caller audio → Twilio → WebSocket → Deepgram (STT)
   - Deepgram sends transcript → CallSession
   - CallSession calls GPT-4o → generates response
   - Response → ElevenLabs (TTS) → audio → Twilio → Caller
4. **Interruption**: New speech detected → stop current TTS → process new input
5. **Timeout**: Silence for 5s → "Thanks for calling!" → hang up

## Troubleshooting

### No audio in either direction
- Check WebSocket is connecting (look for logs)
- Verify `voice_public_url` is accessible from internet
- Check Twilio webhook URL is correct

### STT not working
- Verify Deepgram API key
- Check Deepgram WebSocket connects successfully
- Look for transcript logs

### TTS not working
- Verify ElevenLabs API key
- Check ElevenLabs voice ID is valid
- Monitor HTTP responses from ElevenLabs

### High latency
- Use `gpt-4o-mini` instead of `gpt-4o` for faster responses
- Enable Deepgram's `nova-2` model (already default)
- Use ElevenLabs Turbo v2.5 model (already default)

## Future Enhancements

- [ ] **Space Ghost Mode**: Multi-party talk show with caller queue
- [ ] **Interruption Detection**: Barge-in handling
- [ ] **Persistent Memory**: Remember callers across conversations
- [ ] **Sound Effects**: Audio stingers and transitions
- [ ] **Call Recording**: Archive conversations
- [ ] **x402 Monetization**: Pay-per-call premium line

## License

Same as Lemon Gateway
