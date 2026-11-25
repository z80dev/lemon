# LemonGateway

`lemon_gateway` is an opt-in ingress app for webhook, SMS, and voice. It
submits runs through `LemonCore.RouterBridge`; [LemonRouter](../lemon_router/README.md)
owns execution and conversation ordering.

## Startup

Set `[gateway.ingress] enabled = true` in operator TOML to start the ingress
supervisor, bounded voice task supervisor, and optional health listener.
By default the app starts an empty supervisor and opens no listener.
For run events, see the [bus event catalog](../../docs/platform/bus-events.md).

## Transports

| Transport | Module / Location | Description |
|-----------|-------------------|-------------|
| Telegram | `lemon_channels` (external app) | Telegram Bot API polling/webhooks |
| Discord | `lemon_channels` (external app) | Discord gateway via Nostrum |
| XMTP | `lemon_channels` (external app) | XMTP messaging via Node.js bridge |
| Email | `lemon_channels` (external app) | SMTP outbound + inbound webhook, as a channel plugin |
| Webhook | `Transports.Webhook` | Generic HTTP webhook (sync/async modes) |
| Voice | `Voice.*` | Real-time phone calls via Twilio + Deepgram STT + ElevenLabs TTS |
| SMS | `Sms.*` | Twilio SMS webhooks with verification code tools |

Set `[gateway.ingress] enabled = true` in global `~/.lemon/config.toml` to
allow the three gateway-owned listeners to start. Each requires its own
enable flag below. The generic webhook is registered by default; there is
no `:transports` app-env setting required. Voice and SMS are dedicated Twilio
services, not registry transports. Channel adapters are unaffected.

`TransportRegistry` publishes the transport map and enabled-transport list as one
immutable persistent-term snapshot at startup. All lookups, including enabled
transport enumeration, are process-call-free. Restart the runtime to apply
listener changes. A stopped registry exposes no stale registrations.

Webhook, SMS, and voice are gateway-owned by design, not pending migration: `LemonChannels.Plugin.deliver/1` is fire-and-forget, so it cannot serve webhook's synchronous response, SMS has no reply path at all, and voice needs a live bidirectional session. Email was the one surface that genuinely was a channel, and it moved to `lemon_channels` in phase 2.4 — `LemonChannels.Adapters.Email`. See decision D2 in `docs/platform-split.md`.

Webhook submissions use a caller-fixed run ID. If the router cannot confirm
whether a submission took effect, the HTTP request receives a `200` receipt
with `status: "outcome_unknown"` and `retry_safe: false`; this acknowledges the
webhook delivery without claiming that Lemon accepted the run. Callers must
reconcile the returned run ID instead of automatically redelivering. When an
idempotency key is present, Lemon persists that ambiguous receipt and replays it
without submitting another run. Reservations carry a stable run ID and a
lease-owner token. Submission and response receipts are compare-and-swap
updates owned by that token, and an HTTP success is not returned when the
corresponding durable receipt cannot be stored. An expired pending lease may be
reclaimed without duplicating an already accepted run because the router treats
the fixed run ID as a durable idempotency key. Payload-provided idempotency keys
are opt-in and must be non-empty JSON strings; blank, numeric, list, or object
values receive a bounded `422 invalid idempotency key` response before hashing
or reservation. A legacy pending receipt without a run ID remains a permanent
ambiguous fence after upgrade because its original acceptance outcome cannot be
proven safely; retries receive a duplicate `200 legacy_outcome_unknown` receipt
with `retry_safe: false` and never submit another run.

Each authenticated webhook run carries `meta.channel_context` derived from the
integration whose token matched (`channel_id: "webhook"`, the integration ID as
account and peer), never from the payload. The router applies the group
approval floor from that provenance and refuses a `:webhook` request without
it. A token authenticates the integration, not the content it
relays, so by default the provenance is classified `peer_kind: :automation` and
every `bash`, `write`, `edit`, `patch` and `hashline_edit` call needs approval
(the group approval floor). An operator opts one integration out in the global
config only; gateway sections are operator-only, so a project
`.lemon/config.toml` cannot set it, and only a literal boolean `true` counts:

```toml
[gateway.webhook.integrations.ci]
token = "..."
trusted_automation = true   # no approval floor for this integration
```

The webhook idempotency sweep watermark is volatile ETS state owned by the
supervised `Transports.Webhook.Idempotency` ingress child, not by an HTTP caller.
Only successful cleanup advances it. Owner restart resets the schedule without
changing durable reservations or response receipts; missing supervision skips
opportunistic cleanup rather than creating a caller-owned table. Scheduler's
named stats table is likewise created and owned by its existing supervised child.

## Module Inventory

### Core

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Application` | `application.ex` | Starts opt-in ingress, voice tasks, and health |
| `LemonGateway.IngressSupervisor` | `ingress_supervisor.ex` | Starts gateway-owned webhook, SMS, and voice children |
| `LemonGateway.AI` | `ai.ex` | Direct HTTP chat completions for OpenAI and Anthropic APIs |


### Transport Layer

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Transport` | `transport.ex` | Behaviour for transport plugins |
| `LemonGateway.TransportRegistry` | `transport_registry.ex` | Transport registration and enable/disable tracking |
| `LemonGateway.TransportSupervisor` | `transport_supervisor.ex` | Supervisor for enabled transports |
| `LemonGateway.Transports.Webhook` | `transports/webhook.ex` | HTTP webhook transport (sync/async) |

### SMS

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Sms.Inbox` | `sms/inbox.ex` | Store and query inbound SMS messages |
| `LemonGateway.Sms.WebhookServer` | `sms/webhook_server.ex` | HTTP server for Twilio SMS webhooks |
| `LemonGateway.Sms.WebhookRouter` | `sms/webhook_router.ex` | Plug router for SMS webhook requests |
| `LemonGateway.Sms.TwilioSignature` | `sms/twilio_signature.ex` | Twilio webhook signature validation |
| `LemonGateway.Sms.Config` | `sms/config.ex` | SMS configuration helpers |

### Voice

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Voice.CallSession` | `voice/call_session.ex` | Per-call state machine owning supervised, deadline-bound LLM/TTS work |
| `LemonGateway.Voice.TwilioWebSocket` | `voice/twilio_websocket.ex` | WebSocket handler for Twilio Media Streams |
| `LemonGateway.Voice.DeepgramCall` | `voice/deepgram_call.ex` | Per-call lifecycle and transcript routing for `LemonMedia.Providers.DeepgramStream` |
| `LemonGateway.Voice.WebhookRouter` | `voice/webhook_router.ex` | Voice webhook HTTP routing |
| `LemonGateway.Voice.RecordingManager` | `voice/recording_manager.ex` | Starts dual-channel call recording via Twilio REST API |
| `LemonGateway.Voice.RecordingDownloader` | `voice/recording_downloader.ex` | Downloads and saves Twilio recordings locally |
| `LemonGateway.Voice.AudioConversion` | `voice/audio_conversion.ex` | PCM-to-mulaw and MP3 detection utilities |
| `LemonGateway.Voice.Config` | `voice/config.ex` | Voice configuration (Twilio, Deepgram, ElevenLabs credentials) |

### SMS tools

The running SMS inbox registers these tools through `LemonAgent.ToolRegistry`.
They are not part of the unconditional native tool set.

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Tools.SmsGetInboxNumber` | `tools/sms_get_inbox_number.ex` | Get the Twilio inbox phone number |
| `LemonGateway.Tools.SmsWaitForCode` | `tools/sms_wait_for_code.ex` | Block until a matching SMS verification code arrives |
| `LemonGateway.Tools.SmsListMessages` | `tools/sms_list_messages.ex` | List recent SMS messages |
| `LemonGateway.Tools.SmsClaimMessage` | `tools/sms_claim_message.ex` | Mark an SMS as claimed by the current session |
| `LemonGateway.Tools.SmsReleaseInbox` | `tools/sms_release_inbox.ex` | Release the session's exclusive inbox reservation |

File delivery to Telegram and Discord chats is the channel-keyed `send_file`
tool (`CodingAgent.Tools.SendFile` in `coding_agent`), not a gateway tool.

### Health

| Module | File | Purpose |
|--------|------|---------|
| `LemonGateway.Health` | `health.ex` | Health check system with built-in and custom checks |
| `LemonGateway.Health.Router` | `health/router.ex` | Plug router serving `GET /healthz` (port 4042 by default when ingress is enabled) |

## Queue Semantics

Ingress bindings may select a queue mode for their router-facing run requests.
`SessionCoordinator` owns all queue behavior.

## Voice Call System

Each call serializes LLM generation and speech synthesis through supervised
tasks. Generation has the existing 30-second HTTP budget and synthesis has the
existing 10-second HTTP budget; timeout or task death advances queued work.
Expired task results and best-effort Twilio playback marks cannot advance a
new synthesis. Incoming audio resets the configured silence deadline; unrelated
events do not. Inactivity starts a goodbye with the existing three-second
shutdown budget. Ending the call terminates its active task.

```
Incoming Call -> Twilio -> Voice.WebhookRouter -> CallSession state machine
                                                      |
                                               TwilioWebSocket
                                            (mulaw audio frames)
                                                      |
                                               DeepgramStream
                                            (raw audio -> text)
                                                      |
                                               LemonGateway.AI
                                            (LLM chat completion)
                                                      |
                                           ElevenLabs TTS API
                                            (text -> audio)
                                                      |
                                              Twilio <- audio
```

- `RecordingManager` starts dual-channel recording via the Twilio REST API when a call connects.
- `RecordingDownloader` saves recordings as WAV files organized by date (`~/.lemon/recordings/<date>/`).
- Audio conversion handles PCM-to-mulaw transcoding and MP3/ID3 detection for ElevenLabs responses.

## SMS Inbox

1. Twilio sends SMS webhooks to `Sms.WebhookServer`. Every request must carry a
   valid `X-Twilio-Signature` (`TwilioSignature`); there is no opt-out. A missing
   auth token (`TWILIO_AUTH_TOKEN` or `[gateway.sms] auth_token_secret`) keeps
   the listener from starting, and missing or bad signatures get 403 with
   nothing stored.
2. `Sms.Inbox` and the listener start only when SMS ingress is usable: gateway
   ingress enabled, `[gateway.sms] webhook_enabled`, and an auth token.
   Webhook-only or voice-only deployments run no inbox. The inbox stores
   messages with extracted verification codes (4-8 digit sequences).
3. Native executor runs get the SMS tools (`sms_get_inbox_number`,
   `sms_wait_for_code`, `sms_list_messages`, `sms_claim_message`,
   `sms_release_inbox`) only while SMS ingress is usable and both the inbox and
   listener are running. Their results are untrusted tool output, fenced before
   the model sees them, because SMS bodies are attacker-controlled.
4. The shared number is reserved by one session at a time. Any SMS tool call
   takes the reservation (or reuses the caller's own); other sessions get
   "reserved by another session" with no number or content. Reservations are
   persisted and never expire: the number stays bound to its holder, across runs
   and restarts, until the holder calls `sms_release_inbox` or an operator clears
   it. A text is bound to the session the number is bound to when it arrives,
   and only that session can list, wait for or claim it. Texts arriving while
   the number is unbound are visible to no session. `include_claimed` is not
   available to agents.
5. After an explicit release the number stays bound to the releasing session
   for a handoff grace period (`[gateway.sms] handoff_grace_ms`, default 10
   minutes; zero or invalid values are rejected at config load). Late texts in
   that window go to the releaser, which may re-reserve at any time; every other
   session is refused. Releasing gives up later codes.
6. Operators can force-clear a stuck reservation with the admin control-plane
   method `sms.inbox.clear`: call it without `confirmToken` to preview the
   holder and get a single-use token, then call it with that `holder` and
   `confirmToken`. The clear is bound to that exact holder and reservation and
   frees the number at once, so a late text for the previous holder that arrives
   after another session reserves goes to that session. This is an accepted cost
   of a forced clear.

   A shared number gives ownership only through explicit release; it cannot
   prove which flow a text belongs to. Session-specific numbers are needed for
   stronger isolation.
7. Ingestion is an atomic insert-if-absent keyed by MessageSid: a replayed
   delivery never overwrites the stored message or its claim and is not offered
   again. A store failure answers 503 so Twilio can retry; lease reads are strict,
   so a store failure refuses the lease instead of granting it.

## Binding System

Bindings map `transport + chat_id + topic_id` to a project, agent, and queue mode:

```toml
[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789
topic_id = 42
project = "myproject"
agent_id = "coder"
queue_mode = "steer"
```

`LemonChannels.BindingResolver` (over `LemonCore.BindingResolver`) provides:
- `resolve_binding/1` -- most specific matching binding
- `resolve_cwd/1` -- project root directory
- `resolve_agent_id/1` -- agent identifier
- `resolve_queue_mode/1` -- queue mode from binding

## Configuration

Ingress reads the `[gateway]` section of `~/.lemon/config.toml` live through
`LemonCore.GatewayConfig`. Shared settings may have other owners; for example,
the router applies `[gateway].max_concurrent_runs` even without gateway ingress.
See [configuration](../../docs/config.md#gateway-core-settings).

### Startup Options

| Key | Default | Description |
|-----|---------|-------------|
| `[gateway.ingress] enabled` | `false` | Allow gateway-owned webhook, SMS, and voice listeners to start. `LEMON_GATEWAY_INGRESS_ENABLED` overrides this boolean; restart to apply. |

### Transport Enable Flags

| Key | Default | Description |
|-----|---------|-------------|
| `enable_telegram` | `false` | Enable Telegram adapter (via `lemon_channels`) |
| `enable_discord` | `false` | Enable Discord adapter (via `lemon_channels`) |
| `enable_xmtp` | `false` | Enable XMTP transport |
| `enable_webhook` | `false` | Enable the built-in webhook listener (`LEMON_GATEWAY_ENABLE_WEBHOOK`) |
| `[gateway.sms] webhook_enabled` | `false` | Enable the SMS listener and inbox when a Twilio auth token is configured (`LEMON_SMS_WEBHOOK_ENABLED`) |
| `[gateway.voice] enabled` | `false` | Enable the voice listener; requests need an HTTPS `public_url` and Twilio auth token |

All three gateway listeners bind to loopback by default; use a TLS proxy or
tunnel for external callbacks. See [Gateway ingress](../../docs/config.md#gateway-ingress).

There is no `enable_email` gate. The `[gateway] email` block itself is still meaningful — the
channel adapter reads it, so existing relay credentials, sender address and webhook token keep
working. Receiving mail now depends on `LemonChannels.InboundHttp` being enabled and a
webhook token being set; see `LemonChannels.Adapters.Email`.

Discord and email are not gateway transports. If a `discord` or `email` module is added to
`:transports`, `TransportRegistry` ignores it and logs a warning; ownership lives in
`lemon_channels`.

### TOML Example

```toml
[gateway]
max_concurrent_runs = 2
auto_resume = true

[gateway.telegram]
bot_token = "your-token"
allowed_chat_ids = [123456789]
deny_unbound_chats = true

[gateway.projects.myproject]
root = "/path/to/project"

[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789
project = "myproject"
agent_id = "coder"
queue_mode = "steer"

[gateway.ingress]
enabled = true

[gateway.sms]
webhook_enabled = true
webhook_port = 4041
webhook_url = "https://sms.example.com/webhooks/twilio/sms"
auth_token_secret = "twilio_auth_token"

```

## Health Check

With ingress enabled, the optional health endpoint runs on port 4042 by
default (`:health_port`). `GET /healthz` returns JSON for the supervisor and
ingress checks, including XMTP when enabled. For execution capacity, query
`LemonRouter.Health` instead.

Custom health checks can be registered via the `:health_checks` application environment.

## Dependencies

### Umbrella Apps

| App | Purpose |
|-----|---------|
| `lemon_agent` | Tool registration for the SMS inbox |
| `lemon_core` | Shared primitives: `Store`, `Bus`, `Telemetry`, `ResumeToken`, `ChatScope`, `Binding`, `Secrets`, `GatewayConfig` |

### External Libraries

| Library | Purpose |
|---------|---------|
| `jason` | JSON encoding/decoding |
| `uuid` | UUID generation for run IDs |
| `toml` | TOML configuration parsing |
| `plug` + `bandit` | HTTP servers (health port 4042, SMS webhooks, voice webhooks) |
| `gen_smtp` + `mail` | SMTP email handling |
| `earmark_parser` | Markdown-to-Telegram entity rendering |
| `websock_adapter` | Twilio Media Streams WebSocket ingress |

## Testing

```bash
# Run all gateway tests
mix test apps/lemon_gateway

# Run with verbose output
mix test apps/lemon_gateway --trace
```
