# Gateway → Channels Transport Migration Plan

Status: proposal — investigation complete, no code changes made yet.

Last reviewed: 2026-07-07

## Summary

Five inbound surfaces still live only in `lemon_gateway` as "transitional legacy
ingress" behind `:legacy_ingress_enabled`: email, farcaster, webhook, SMS, and
voice. The migration to `lemon_channels` has stalled for a structural reason,
not a procrastination reason: three of these five are not "channels" in the
sense `LemonChannels.Plugin` was designed for, and porting them as-is would
force a redesign of the plugin contract, not just a file move.

- **SMS is not a channel.** It has no conversational reply path at all — it is
  a passive OTP/verification-code inbox exposed to the agent as four gateway
  tools (`SmsGetInboxNumber`, `SmsWaitForCode`, `SmsListMessages`,
  `SmsClaimMessage`). It should not go to `lemon_channels`; it belongs with
  gateway-injected tooling.
- **Webhook and Farcaster are synchronous, non-conversational integrations.**
  Webhook is a generic HTTP trigger for external automation (Zapier/n8n/Make),
  and Farcaster is a stateless per-request Frame action handler. Both must
  produce their HTTP response in the same request cycle that received the
  inbound call. `LemonChannels.Plugin.deliver/1` is fire-and-forget
  (`{:ok, delivery_ref}`) with no way to return a value into the request that
  triggered it — there is no synchronous round-trip in the plugin contract.
- **Voice requires a live bidirectional session**, not a message. Twilio Media
  Streams + Deepgram STT run over a persistent WebSocket with real-time
  turn-taking, and `call_session.ex` intentionally bypasses the full
  `coding_agent` tool-loop in favor of a bespoke `LemonGateway.AI.chat_completion/3`
  call for latency. Nothing in `normalize_inbound/1` → `deliver/1` models a
  stateful, streaming, sub-second-turnaround session.
- **`lemon_channels` has no inbound HTTP server today.** It depends on neither
  `plug` nor `bandit`, and every existing adapter (Telegram, Discord, WhatsApp,
  X API, XMTP) is polling-, websocket-client-, or bridge-process-based. Email,
  webhook, SMS-webhook, and voice-webhook all require *receiving* HTTP POSTs on
  a bound port — infrastructure that must be built from scratch in
  `lemon_channels`, not reused.
- **Email is the best-fit candidate** for a real port: async, store-and-forward,
  already conceptually message-shaped (sender/thread/attachments), and the
  Plugin gaps (multi-ancestor threading, inbound HTTP hosting) are additive,
  not architectural mismatches.

Net recommendation: port email now, keep SMS in gateway tooling permanently,
and treat webhook/farcaster/voice as durable gateway-owned integration
surfaces unless/until the Plugin contract grows synchronous-response and
session primitives — which is a bigger investment than this migration alone
justifies today.

## Context: why this stalled

`docs/architecture_boundaries.md` describes gateway-native transport, command,
SMS, and voice startup as "transitional legacy ingress" requiring explicit
`:legacy_ingress_enabled` (`apps/lemon_gateway/lib/lemon_gateway/application.ex:63-73`,
`apps/lemon_gateway/lib/lemon_gateway/legacy_ingress_supervisor.ex`). Telegram
and Discord already completed the intended migration:
`LemonGateway.TransportRegistry` hard-codes
`@channels_owned_transport_ids ~w(discord)` and warns at startup if anyone
tries to re-register a channels-owned transport ID
(`apps/lemon_gateway/lib/lemon_gateway/transport_registry.ex:16,51-59`); its
`init/1` comment says Telegram polling is "intentionally empty by default...
owned by lemon_channels." WhatsApp was ported the same way and lives entirely
under `apps/lemon_channels/lib/lemon_channels/adapters/whatsapp/`. So the
playbook is proven — the problem is that the next five transports don't fit
the shape the playbook assumes.

`docs/for-dummies/05-the-engine-room.md:238-239` states the actual gateway
transport pattern plainly: "All transports follow the same pattern: normalize
the inbound to a `RunRequest`, submit via `RouterBridge`." This is a different
contract than the channels path (`normalize_inbound/1` → `LemonCore.InboundMessage`
→ `LemonRouter.Router`, which owns session/queue semantics and calls
`RouterBridge` itself downstream). Gateway transports build `LemonCore.RunRequest`
directly and call `LemonCore.RouterBridge` themselves, which is how
webhook/farcaster get low-level control they need: explicit `queue_mode`,
sync-vs-async response mode, callback delivery with retry, and idempotency —
none of which the channels path currently exposes to a plugin author.

## Current-state inventory

| Transport | Entry point | Source LOC | Test LOC | Coupling to gateway internals |
|---|---|---|---|---|
| Email | `LemonGateway.Transports.Email` (GenServer + Bandit-backed `Inbound`/`Outbound`) | 2,114 (`transports/email.ex` 100, `email/inbound.ex` 1,299, `email/outbound.ex` 715) | 294 (inbound-security only; `outbound.ex` has **zero** dedicated tests) | `LemonCore.RouterBridge`, `RunRequest`, `Store` (thread-state tables), `LemonGateway.Config` |
| Farcaster | `LemonGateway.Transports.Farcaster` → `FrameServer` (Plug/Bandit) → `CastHandler` | 1,199 (`transports/farcaster.ex` 96, `cast_handler.ex` 718, `frame_server.ex` 188, `hub_client.ex` 197) | 239 (one transport-level test file) | `LemonCore.RouterBridge`, `RunRequest`, `ChatStateStore`, `SessionKey`, `ChatScope`, `LemonGateway.BindingResolver`, `Secrets` |
| Webhook | `LemonGateway.Transports.Webhook` (Plug/Bandit) + `Config`/`Idempotency`/`SignatureValidation`/`RequestNormalization`/`Submission`/`ResponseBuilder`/`InvocationDispatch` | 1,777 across 10 files | 276 (one integration-level test; **no** dedicated tests for `Idempotency`, `SignatureValidation`, `Submission`, `RequestNormalization`) | `LemonCore.RunRequest`, `RouterBridge`, `Store` (idempotency table + `:global.trans` lock), `LemonCore.Bus` (sync subscription wait) |
| SMS | `LemonGateway.Sms.Inbox` (GenServer) + `WebhookServer`/`WebhookRouter` (Plug/Bandit) + `TwilioSignature` | 937 across 6 files | 583 (best-tested transport, mostly `twilio_signature_test.exs`) | **No** `RouterBridge`/`RunRequest` usage at all — purely a `Store`-backed inbox queried by 4 gateway-injected tools in `lemon_gateway/lib/lemon_gateway/tools/sms_*.ex` |
| Voice | `LemonGateway.Voice.CallSession` (GenServer) + `TwilioWebsocket`/`WebhookRouter` (Bandit) + `DeepgramClient`/`RecordingDownloader`/`RecordingManager`/`AudioConversion` | 1,658 across 8 files | 430 (`call_session_test.exs` 100 of 461 LOC covered; `DeepgramClient`, `RecordingDownloader`, `RecordingManager` — 384 LOC combined — have **zero** dedicated tests) | Bypasses `RouterBridge`/`RunRequest`/`coding_agent` tool-loop entirely; calls `LemonGateway.AI.chat_completion/3` directly for latency; owns live WebSocket sessions (`Voice.CallSessionSupervisor`, `Voice.DeepgramSupervisor`) |

All five are gated by `:legacy_ingress_enabled` (default `false`) plus their
own per-transport `enable_*` config flag (also default `false`/unset in
`config/*.exs` — none of `enable_email`, `enable_farcaster`, `enable_webhook`
appear anywhere in the checked-in config). That means in a stock `./bin/lemon`
run today, none of these five even start. This matters for the disposition
call below: there's no evidence of default/mainstream usage forcing an
urgent port, which argues for prioritizing by architectural fit and blast
radius rather than by usage pressure.

### Feature detail (auth, media, threading, delivery)

- **Email**: full RFC 2822 threading (`In-Reply-To`/`References` merge with
  persisted `email_message_threads`/`email_thread_state` tables), attachment
  upload + async persistence with size caps, markdown→HTML rendering for
  outbound, direct SMTP send, webhook-token auth (constant-time compare).
- **Farcaster**: Hub-signature verification via `HubClient` (already migrated
  to `LemonCore.Httpc` — good precedent for the HTTP client boundary), frame
  state round-tripped through URL/session-ref tokens, synchronous HTML
  response built in the same request that received the action, optional cast
  posting via signer credentials.
- **Webhook**: per-integration signature validation (`SignatureValidation`),
  idempotency-key reservation with a global lock and cached duplicate
  response replay, sync mode (wait for run completion, return full result) or
  async mode (return immediately, deliver result to a callback URL with
  retry/backoff), private-host allowlisting for callback URLs.
- **SMS**: Twilio HMAC signature validation, TTL-based inbox with waiter
  fulfillment (`wait_for_code`), regex-based code extraction — no outbound
  reply capability, no conversational routing.
- **Voice**: Twilio signature validation, live audio streaming both
  directions, Deepgram streaming STT, ElevenLabs TTS, PCM→mu-law conversion,
  call recording start/stop + authenticated async download, non-agentic direct
  LLM completion for turn responses.

## Plugin API gap analysis (the key deliverable)

`LemonChannels.Plugin` (`apps/lemon_channels/lib/lemon_channels/plugin.ex`) has
six callbacks: `id/0`, `meta/0`, `child_spec/1`, `normalize_inbound/1` (raw →
`LemonCore.InboundMessage`), `deliver/1` (`LemonChannels.OutboundPayload` →
`{:ok, delivery_ref}`), `gateway_methods/0` (control-plane RPC methods for
agent-triggered outbound actions, e.g. `XAPI.GatewayMethods.post_tweet/1`).
`meta/0`'s `capabilities` map (e.g. WhatsApp declares
`voice_support: true, image_support: true, thread_support: true`) is free-form
descriptive metadata, not an enforced interface — declaring `voice_support`
today means "can send/receive voice-note attachments," which is a different
capability entirely from a live telephony session.

| Gap | Needed by | Why the current API can't express it |
|---|---|---|
| **Synchronous request/response round-trip.** Nothing lets a plugin return a value that becomes the HTTP response to the request that triggered `normalize_inbound`. | Webhook (sync mode), Farcaster (every frame action) | `deliver/1` is decoupled and async by design (`{:ok, delivery_ref}`); there is no callback path from delivery back to the original inbound HTTP connection. |
| **Idempotency-key dedup + duplicate-response replay.** | Webhook | No hook in the plugin lifecycle for a keyed reservation/replay step before `normalize_inbound` runs. |
| **Per-request queue-mode / execution-mode override** (sync-wait vs. async, `collect`/`followup`/`steer`/`interrupt`). | Webhook, Farcaster | `InboundMessage` has no field for this; `LemonRouter.Router` picks session/queue behavior itself from conversation state, not from a per-message override. |
| **Callback delivery with retry/backoff to a caller-supplied URL.** | Webhook | Entirely absent; this is Lemon *calling out* to an arbitrary third-party URL with the run result, which is a different responsibility than delivering into a channel. |
| **Inbound HTTP server hosting** (bind port, parse multipart/urlencoded/json, per-path routing). | Webhook, Email (webhook mode), SMS-webhook, Voice-webhook | `lemon_channels` has zero `plug`/`bandit` dependency today; every adapter is a client (poller, websocket client, or bridge process), never a listener. This is new infrastructure, not a missing callback. |
| **Live bidirectional session / streaming media.** | Voice | The whole model is "one raw payload in → one `InboundMessage` out"; there's no concept of an open session with many turns, external STT/TTS legs, or sub-second latency budgets that bypass the normal run pipeline. |
| **Multi-ancestor thread resolution** (a message can reference N prior message-IDs, not one `reply_to_id`). | Email | `InboundMessage.message.reply_to_id` is a single optional ID; email's `References` header is a list requiring union-find-style merge logic. Solvable as channel-owned state (like Telegram's own tables), not a hard blocker, but worth calling out since it's real complexity the adapter must still own. |
| **Tool-only capability with no inbound/outbound message shape at all.** | SMS | Not a gap in the Plugin API — SMS simply isn't a channel. Forcing it through `normalize_inbound`/`deliver` would be a category error. |

## Disposition recommendations

| Transport | Disposition | Justification |
|---|---|---|
| **Email** | **Port, with plugin-API extension for multi-ancestor threading** | Best structural fit: async, store-and-forward, message-shaped. Needs: (1) new inbound-HTTP-hosting capability in `lemon_channels` (shared with nothing else if webhook/voice stay in gateway — see below), (2) a thread-resolution helper that can live channel-side without a Plugin API change, (3) attachment handling, which `OutboundPayload.kind :file` and WhatsApp's existing `image_support`/`file_support` precedent already cover on the outbound side. Untested `outbound.ex` (715 LOC, 0 dedicated tests) is a real risk to carry into the port — write characterization tests before moving, not after. |
| **Webhook** | **Keep in gateway indefinitely** | Not a channel — it's a generic external-automation trigger (Zapier/n8n/Make per `docs/for-dummies/05-the-engine-room.md`). Its defining features (sync response, idempotency, callback retry) are integration-gateway concerns, not channel-delivery concerns. Porting would require inventing synchronous-response and idempotency primitives in the Plugin API purely to serve one non-channel use case — not worth the API surface growth. If/when a second synchronous-integration transport appears, consider a *separate* `LemonGateway.Integrations` or `lemon_control_plane`-owned surface rather than stretching `LemonChannels.Plugin`. |
| **Farcaster** | **Keep in gateway indefinitely (retire candidate — confirm usage first)** | Same synchronous-response mismatch as webhook, plus it's off by default with no evidence of production usage (no default config, single doc mention as a feature list bullet, no dedicated usage signal found). Before investing further, confirm with the team whether Farcaster has any live users; if not, retiring it (deleting the transport, keeping `HubClient`'s Httpc pattern as reference) is cheaper than maintaining or porting it. Do not retire unilaterally in this pass — this plan only flags it as a candidate pending an ownership decision. |
| **SMS** | **Keep in gateway/tools indefinitely — do not migrate to `lemon_channels` at all** | It is agent tooling (`SmsGetInboxNumber`/`SmsWaitForCode`/`SmsListMessages`/`SmsClaimMessage`), not a channel; it has no outbound reply path and no `InboundMessage`/`RunRequest` construction. `lemon_channels` doesn't depend on `coding_agent` (and per `docs/architecture_boundaries.md` isn't allowed to), so the tool registrations couldn't move there even if desired. Its natural long-term home, if it moves at all, is alongside other gateway-injected tools or `lemon_skills` assistant-platform tools — a separate, smaller project from this migration. |
| **Voice** | **Port only with a major plugin-API extension (highest risk, lowest priority)** | Requires session/streaming primitives (live WebSocket state, external STT/TTS legs, sub-agentic-loop LLM turns) that don't exist anywhere in the Plugin contract today, and would likely need their own behaviour (e.g. `LemonChannels.CallPlugin`) rather than reusing `normalize_inbound`/`deliver`. Combine with the weakest test coverage of the five (0 tests on `DeepgramClient`/`RecordingDownloader`/`RecordingManager`, 100/461 LOC on `CallSession`) and this is the transport most likely to regress silently if touched. Recommend addressing only after email's port validates the new inbound-HTTP-hosting infrastructure, and only if there's a concrete roadmap need (e.g. a second telephony provider) forcing the abstraction. |

## Phased plan

### Phase 0 — Decision checkpoint (no code)
Confirm with the team: (a) is Farcaster used anywhere real — if not, file a
separate retirement task instead of folding it into this migration; (b) accept
that webhook and SMS are staying put permanently, so `:legacy_ingress_enabled`
will **not** fully retire — it will shrink to cover webhook + SMS + voice
(+ farcaster, pending 0a) rather than disappear. Update
`docs/architecture_boundaries.md`'s "transitional legacy ingress" language to
reflect the corrected end state instead of implying full retirement is the
goal.

### Phase 1 — Build inbound-HTTP-hosting capability in `lemon_channels`
Add `plug`/`bandit` as a `lemon_channels` dependency (new, currently absent)
and a small shared `LemonChannels.InboundHttp` supervisor/router shell,
modeled on `LemonGateway.Transports.Webhook`'s Bandit wiring but generic
enough for email's webhook-ingest mode. This is prerequisite infrastructure,
not part of email's own code — keep it as its own reviewable PR so the
"can `lemon_channels` host inbound HTTP at all" risk is validated in
isolation before email logic lands on top of it.
**Risk:** low in isolation (no behavior change, additive dependency), but this
is the one step that must not be skipped or rushed — get it wrong and every
downstream port inherits the bug. **Scope:** ~1 small PR, 1-2 days.

### Phase 2 — Port email
1. Write characterization tests for current `email/inbound.ex` and
   `email/outbound.ex` behavior first (0 dedicated tests on `outbound.ex`
   today) — do this against the existing gateway code before moving anything,
   so regressions are caught in the port itself.
2. Build `LemonChannels.Adapters.Email` implementing `LemonChannels.Plugin`,
   reusing Phase 1's inbound-HTTP shell; move thread-resolution and attachment
   logic largely as-is (they're channel-owned business logic, not gateway
   internals).
3. Run both implementations side by side behind separate config flags (same
   pattern Telegram/Discord used — `TransportRegistry`'s
   `@channels_owned_transport_ids` warns against dual registration; extend
   that list once email cuts over).
4. Cut over, delete `apps/lemon_gateway/lib/lemon_gateway/transports/email/`,
   remove `email` from gateway's transport registry defaults.
**Risk:** medium — untested outbound threading/attachment logic is the main
exposure; mitigated by step 1. **Scope:** ~3-4 PRs (characterization tests,
inbound port, outbound port, cutover), 1-2 weeks.

### Phase 3 — Farcaster retirement or explicit keep decision
Execute whatever Phase 0 decided: either delete
`apps/lemon_gateway/lib/lemon_gateway/transports/farcaster/` (keeping
`HubClient`'s `LemonCore.Httpc` usage pattern as a reference if useful
elsewhere), or formally document it as a permanent gateway-owned integration
alongside webhook. **Risk:** low (isolated module, already off by default).
**Scope:** ~1 day either way.

### Phase 4 — Document the corrected end state, narrow `:legacy_ingress_enabled`
Update `docs/architecture_boundaries.md` and
`apps/lemon_gateway/lib/lemon_gateway/legacy_ingress_supervisor.ex`'s
moduledoc to describe the *actual* target: SMS, webhook, and voice (and
farcaster, if kept) remain permanent gateway-owned ingress, not transitional.
Rename or re-scope `:legacy_ingress_enabled` if the "legacy" framing is no
longer accurate for surfaces that are staying by design rather than by
neglect. **Risk:** none (docs + config naming only). **Scope:** ~1 day.

### Phase 5 — Voice (conditional, not scheduled)
Only start this if a concrete product need emerges (e.g., a second telephony
provider, or a requirement to route voice calls through the standard
conversational pipeline). Prerequisite work: design a session-oriented
extension to `LemonChannels.Plugin` (or a sibling behaviour) with real
characterization test coverage on `CallSession`/`DeepgramClient`/
`RecordingDownloader`/`RecordingManager` written *before* any refactor, given
current coverage is the thinnest of the five. **Risk:** high (live audio,
external STT/TTS vendors, latency-sensitive, weakest existing tests).
**Scope:** not estimated — treat as its own follow-up plan once triggered.

## Testing strategy

- Before touching any transport: add characterization tests for the paths
  with weak/zero coverage identified above (`email/outbound.ex`,
  webhook's `Idempotency`/`SignatureValidation`/`Submission`, voice's
  `DeepgramClient`/`RecordingDownloader`/`RecordingManager`). This applies
  regardless of whether a transport is being ported or kept — these are gaps
  today, independent of this migration.
- For email's port: run old (gateway) and new (channels) implementations
  behind separate flags in a staging config before cutover, comparing
  delivered message shape and thread continuity on the same test mailbox.
- Structural test: extend `mix lemon.quality`'s architecture check to flag if
  `lemon_gateway` and `lemon_channels` ever gain a direct dependency on each
  other (they currently have none — worth locking in explicitly given this
  migration is the exact scenario that would tempt someone to add one as a
  shortcut).

## Catalog registration

This document is registered in `docs/catalog.exs` as part of this task
(owner `@z80`, `last_reviewed: ~D[2026-07-07]`, `max_age_days: 180`).
