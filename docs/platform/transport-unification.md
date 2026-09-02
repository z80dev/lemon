# Phase 2.4 — Transport Unification: Inventory and Port Design

Status: **design (Phase A).** Written 2026-08-10 against `463db837..8f76026d`.

> **Update 2026-08-10:** the Farcaster transport has been **deleted** (D12; ~1.4k LOC incl.
> tests). The inventory below has been updated to the post-deletion tree; the analysis of why
> it did not fit `Plugin` is retained because it is the reasoning behind the decision.

This document records the verified inventory, control-plane coupling, environment
variables, chat-state dependency, Telegram surfaces, and the recommended amendment
to **D2**.

## 1. Headline recommendation

**Amend D2.** D2 says: *"Email/farcaster/webhook/sms/voice move to `lemon_channels` as `Plugin`
implementations; `LemonGateway.Transport` behaviour is deleted; one transport concept remains."*

The evidence does not support that for four of the five. Recommended disposition:

| Subsystem | D2 says | Recommended | Why (one line) |
|---|---|---|---|
| Email | port | **Port** | Genuinely message-shaped and async; the only clean fit. |
| Farcaster | port | **Deleted** (D12, executed) | Synchronous frame response; off by default; no evidence of use. |
| Webhook | port | **Keep in gateway** | Not a channel — a generic sync HTTP automation trigger. |
| SMS | port | **Keep in gateway tooling** | Not a channel at all: no reply path, exposed as 4 agent tools. |
| Voice | port | **Defer** | Live bidirectional streaming session; nothing in `Plugin` models it. |

Consequently **`LemonGateway.Transport` cannot simply be deleted** in 2.4. What *can* be
achieved — and what I recommend 2.4 actually deliver — is stated in §7.

The "one transport concept remains" goal is still reachable, but by a different route than
deletion: the honest end state is *two* concepts with a clear, documented boundary —
`LemonChannels.Plugin` for conversational channels, and a gateway-owned integration surface for
synchronous/tooling/streaming ingress. Pretending the latter is a channel is what has kept this
migration stalled since July.

## 2. Current-state inventory

### 2.1 What is actually a "transport"

Only **two** subsystems implement `LemonGateway.Transport`:
`transports/email.ex` and `transports/webhook.ex` (farcaster was the third until D12 deleted
it). **SMS and voice do not** — they are independent supervised subsystems that happen to start
under the same supervisor. Any framing of "the five gateway transports" is inaccurate; it is two
transports plus two unrelated Twilio subsystems.

### 2.2 The behaviour itself is nearly empty

`LemonGateway.Transport` (`transport.ex`, 67 LOC) has **two** required callbacks — `id/0` and
`start_link/1` — plus an optional `child_spec/1` supplied by its `__using__` macro. It has no
delivery, no normalization, no metadata. It is a supervised-worker registration marker.

`LemonChannels.Plugin` (`plugin.ex`, 107 LOC) has **six**: `id/0`, `meta/0`, `child_spec/1`,
`normalize_inbound/1`, `deliver/1`, `gateway_methods/0`.

This asymmetry is the crux: porting is not a rename. Every ported subsystem must *grow* four
callbacks it has no implementation for today, and for three of the four remaining the two central
ones (`normalize_inbound/1` → `deliver/1`) are the wrong shape for what the subsystem does.

### 2.3 Size and coverage

| Subsystem | Source LOC | Test LOC | Implements `Transport`? | Reaches router via |
|---|---:|---:|---|---|
| Email | 2,114 | 294 | yes | `RouterBridge` + `RunRequest` |
| Webhook | 1,777 | 357 | yes | `RouterBridge` + `RunRequest` |
| Voice | 1,658 | 430 | **no** | none — calls `LemonGateway.AI.chat_completion/3` directly |
| SMS | 937 | 583 | **no** | none — `Store`-backed inbox read by 4 agent tools |
| `transport.ex` + `transport_registry.ex` + `transport_supervisor.ex` | 240 | — | — | — |

Total ≈ **6.7k LOC** after the farcaster delete (it was 7.9k with farcaster, and the 5.1k
quoted in §3/E3 of the plan of record predated counting SMS and voice).

Coverage is uneven in exactly the places a port would be riskiest: `email/outbound.ex` (715 LOC)
has **zero** dedicated tests, and voice's `DeepgramClient`/`RecordingDownloader`/
`RecordingManager` (384 LOC combined) have zero.

### 2.4 None of it runs by default

Two independent gates are both off:

1. `LemonGateway.LegacyIngressSupervisor` — which hosts `TransportRegistry`,
   `TransportSupervisor`, `CommandRegistry`, both SMS children, and all four voice
   registries/supervisors — starts only when `:legacy_ingress_enabled` is true.
   `application.ex:72` defaults it to `false`, and **no checked-in config sets it** (only two
   SMS test files flip it).
2. `TransportRegistry.init/1` reads `:transports`, defaulting to `[]`. **No config sets it
   either** — `config/test.exs` explicitly sets `[]`.

So in a stock run, zero of these ~6.7k LOC execute. This is the single most important input to
sequencing: there is **no user-facing urgency**, and therefore no reason to accept risk. It also
means "deleting" a subsystem is far cheaper than porting it, and that any port can be validated
without a migration window.

## 3. Mapping onto `LemonChannels.Plugin`

Re-verified 2026-08-10: **`lemon_channels` still has no `plug` or `bandit` dependency**
(`mix.exs` deps: lemon_core, lemon_media, agent_core, jason, earmark_parser, req, nostrum). Every
existing adapter is a *client* — poller, websocket client, or bridge process. Nothing in
`lemon_channels` can receive an inbound HTTP POST on a bound port today. Email, webhook,
SMS-webhook and voice-webhook all require exactly that. This is new infrastructure, not a
missing callback, and it is the prerequisite for any port at all.

Per-callback fit:

| | Email | Webhook | SMS | Voice |
|---|---|---|---|---|
| `id/0` | ✅ | ✅ | ✅ | ✅ |
| `meta/0` | ✅ | ⚠️ meaningless | ⚠️ meaningless | ⚠️ `capabilities` is free-form prose; `voice_support` already means "voice *notes*", not telephony |
| `child_spec/1` | ✅ | ✅ | ✅ | ✅ |
| `normalize_inbound/1` | ✅ | ⚠️ arbitrary JSON trigger | ❌ nothing to normalize | ❌ audio frames, not a message |
| `deliver/1` | ✅ | ❌ **must return into the originating HTTP request**, plus callback-URL delivery | ❌ no reply path exists | ❌ streaming audio over a live socket |
| `gateway_methods/0` | ✅ (none needed) | ✅ | ✅ | ✅ |

The blocking gaps, restated precisely (this is the deliverable the plan-of-record asked for):

1. **No synchronous round-trip.** `deliver/1` returns `{:ok, delivery_ref}` and is decoupled from
   the inbound call. Webhook (sync mode) must produce its HTTP response *in the request cycle
   that received the input* — as did every farcaster frame action, which is what made farcaster
   the hardest case before it was deleted. There is no path from `deliver/1` back to the
   originating connection.
2. **No idempotency hook.** Webhook reserves an idempotency key under a `:global.trans` lock and
   replays cached duplicate responses, before any normalization. The plugin lifecycle has no
   pre-normalize step.
3. **No per-request queue/execution mode.** Webhook sets `queue_mode` and sync-vs-async
   per call. `InboundMessage` has no such field; `LemonRouter` derives queue behaviour from
   conversation state by design (and 2.6 just hardened that).
4. **No outbound-callback delivery.** Webhook POSTs results to a caller-supplied URL with
   retry/backoff and private-host allowlisting. That is Lemon calling *out* to a third party —
   a different responsibility from delivering into a channel.
5. **No inbound HTTP hosting** (§3 above).
6. **No session/streaming primitive.** Voice holds a live Twilio Media Streams socket with
   Deepgram STT and sub-second turn-taking, deliberately bypassing the agent loop for latency.
   `normalize_inbound → deliver` is one-payload-in/one-payload-out.
7. **Single-ancestor threading.** `InboundMessage.message.reply_to_id` is one optional ID; email's
   `References` header is a list needing union-find merge. Real work, but adapter-owned state,
   not an API blocker — this one is solvable without touching `Plugin`.

Gaps 1–4 exist *only* to serve non-channel use cases. Adding them to `Plugin` would enlarge the
platform's most important extension point — the one third parties are meant to implement — for
subsystems that are not channels and are off by default. That is the wrong trade.

## 4. What deleting `Transport` + `TransportRegistry` breaks

- **`LemonControlPlane.Methods.TransportsStatus`** is the only runtime consumer. It already
  reaches the registry through a *dynamic atom* indirection (`transport_registry_module()` +
  `Code.ensure_loaded?` + `function_exported?` + `apply`), degrading to
  `"status" => "registry_stopped"` when absent. Two consequences: (a) deleting the registry does
  not crash it, it just reports empty; (b) **this is the same anti-pattern 2.5 is removing** for
  `LemonGateway.Config`/`EngineRegistry`. Recommendation: fold `transports.status` into 2.5's
  `EngineInfoBridge` work rather than 2.4 — it is the same fix, and doing it twice is waste.
- **Docs asserting the current design**: `apps/lemon_gateway/README.md:126,369`,
  `apps/lemon_gateway/AGENTS.md:3,25`, `docs/architecture_boundaries.md:58`. All describe the
  ingress set as "transitional legacy" implying eventual full retirement. If the recommendation
  here is accepted, that language is simply **wrong** and should be corrected to "permanent
  gateway-owned integration surface" regardless of whether any port happens.
- **Config surface**: `:transports` (registry input) and `:legacy_ingress_enabled` (supervisor
  gate). Neither is set anywhere; both are documented in the gateway README's config table.
- **Doctor checks**: none reference `TransportRegistry`. `LemonCore.Doctor.ChannelDiagnostics`
  hard-codes `@supported_transports [:telegram, :discord]` — see §6.
- **Env vars** (post-1.9, now in `LemonGateway.Env`): 14 declarations, of which **10** are
  `area: :gateway_sms` and **2** `area: :gateway_voice`. (The 5 farcaster vars under
  `area: :gateway` went with the transport in D12.) SMS and voice stay in gateway, so **none of
  the remaining 14 move**, and email/webhook configuration is TOML/`LemonGateway.Config`-driven
  rather than env-var-driven. This is a much smaller migration than "move the env vars to
  channels."

## 5. The chat_state unblock — the Deferred item's premise is wrong

Deferred item (`platform-split.md:200`) says the `chat_state`/`chat_state_store` → router move is
*"blocked until gateway stops writing chat state (run.ex finalization + farcaster handler) — fold
into Phase 2.4."*

Verified writes in `lemon_gateway`:

| Site | What it does | Transport-owned? |
|---|---|---|
| `run.ex:668` → `maybe_store_chat_state/2` → `store_chat_state/2` (`:958`) | On `:completed` with a `ResumeToken`, persists `%ChatState{}` | **No** |
| `run.ex:617` → `maybe_clear_chat_state_on_context_overflow/2` (`:925`) | `ChatStateStore.delete/1` on context-overflow | **No** |

(A third site, `transports/farcaster/cast_handler.ex:248`, deleted `ChatStateStore` entries when
re-keying a frame session; it was the only transport-owned writer and died with the transport in
D12.)

The two `run.ex` sites are in `LemonGateway.Run`'s **finalization path**, which executes for
*every* run regardless of ingress. They have nothing to do with transports. **2.4 will not remove
them, and therefore does not unblock the chat_state move.**

Recommendation: **decouple the chat_state item from 2.4.** The real question is who owns
resume-token persistence at run finalization — gateway (writer today) or router (owner of
conversation state, and already the only *reader*; the `:gateway_auto_resume_mutation`
architecture rule forbids gateway reading chat state to mutate requests, so the split is already
half-enforced). That is a focused ~2-site change worth its own task, and it is blocked on
nothing. Doing it independently would let `chat_state` move to router without waiting on any
transport work at all.

## 6. Telegram surfaces (Deferred item, `platform-split.md:199`)

`LemonCore.Doctor.ChannelDiagnostics` hard-codes `@supported_transports [:telegram, :discord]`
(`channel_diagnostics.ex:8`, used at `:21`, `:23`, `:198`) to classify bindings as supported vs
unsupported. Sibling surfaces: `config.ex`'s gateway-telegram block conversion,
`channel_readiness`, and `inbound_message` naming.

**Recommendation: make it a channel-registered capability, but not in 2.4.** The correct shape is
that `ChannelDiagnostics` asks the channels registry which adapters are registered, instead of
naming two of them in core — the same inversion as `EngineInfoBridge` (2.5) and the
`MethodProvider` registry (2.2/D9). Since `Plugin.meta/0` already returns a `capabilities` map,
the data exists; what is missing is a core-side bridge so `lemon_core` can ask without depending
on `lemon_channels`.

This is genuinely blocked on **2.3** (x_api is proving the runtime self-registration path) and
overlaps **2.5** (bridge pattern). It is not blocked on transport unification. Move it out of
2.4 and attach it to 2.5, where the identical bridge is already being built.

## 7. What 2.4 should actually deliver

> **Status 2026-08-10.** D2 amended in the plan of record; 2.4 rescoped to email-only.
> **A1 resolved:** (b) accepted — webhook/SMS/voice are permanent gateway-owned ingress;
> (a) answered — Farcaster is unused, so it was **deleted** (D12, C1 below).
> **A2, A3 and B1 are done** (see the table). B2/B3 await the go-ahead.
> C2/D1/D2' were re-assigned: chat_state became its own task, and transports.status,
> capability delegation and the telegram surfaces went to 2.5.

Given §1–§6, I recommend re-scoping 2.4 from "port five, delete a behaviour" to
**"establish the boundary, then port the one that fits."**

### Work items

| # | Item | Size | Collides with 2.3? |
|---|---|---|---|
| **A1** ✅ | **Decision checkpoint (no code).** Confirm: (a) is Farcaster used by anyone? (b) accept SMS + webhook + voice as permanent gateway-owned ingress. Everything below depends on (b). | S | No |
| **A2** ✅ | Correct the "transitional legacy ingress" language in `docs/architecture_boundaries.md:58`, `apps/lemon_gateway/README.md:126,369`, `apps/lemon_gateway/AGENTS.md:3,25` to describe the real end state. Amend **D2** in `platform-split.md` §4 and the 5.1k LOC figure in §3/E3. | S | No |
| **A3** ✅ | Rename/re-scope `:legacy_ingress_enabled` — it gates surfaces that are staying by design, so "legacy" is misleading. Suggest `:gateway_ingress_enabled`. | S | No |
| **B1** ✅ | **Characterization tests before any move**: `email/outbound.ex` (715 LOC, 0 tests). Also worth doing regardless of this migration: webhook's `Idempotency`/`SignatureValidation`/`Submission`, voice's `DeepgramClient`/`RecordingDownloader`/`RecordingManager`. | M | No |
| **B2** | **Inbound HTTP hosting in `lemon_channels`**: add `plug` + `bandit` deps and a small `LemonChannels.InboundHttp` supervisor/router shell. Own PR — this is the "can channels host HTTP at all" risk, validated in isolation. | M | **YES** — `lemon_channels/mix.exs` + application supervision tree; 2.3 is editing adapter registration/config/capabilities. Sequence after 2.3 lands. |
| **B3** | **Port email** to `LemonChannels.Adapters.Email` on top of B2: inbound, then outbound, then cutover. Add `email` to `TransportRegistry`'s `@channels_owned_transport_ids` (the mechanism Telegram/Discord/WhatsApp already used). Delete `gateway/transports/email/`. | L | **YES** — new adapter under `lemon_channels/adapters/`, plus adapter registration. Strictly after 2.3. |
| **C1** ✅ | Farcaster: execute A1(a) — **deleted** 2026-08-10 (transport, tests, config keys, 5 env vars, docs). | S | No |
| **E1** | **Capability delegation** (§7a): widen `Plugin.meta/0` to the typed vocabulary, resolve `Capabilities.Registry.lookup/1` through the registered adapter, delete the 5 hard-coded clauses, relocate the per-channel assertions. Unblocked now that 2.3 has landed. | M | No (2.3 complete) |
| **C2** | Fold `transports.status`'s dynamic-atom registry peek into **2.5**'s bridge work rather than solving it here. | S | No (belongs to 2.5) |
| **D1** | Move the chat_state item **out** of 2.4 into its own task (§5). | S | No |
| **D2'** | Move the telegram-surfaces item **out** of 2.4 and attach to **2.5** (§6). | S | No |

### Sequencing

A1 → A2/A3 (docs, parallel, no collisions, can start immediately) → B1 (tests, no collisions) →
B2 → B3. C1 is done and was independent of the rest. **2.3 has since landed**, so the former block on B2/B3 is clear. E1 (§7a) is
independent of the port and can run in parallel with B1. C2/D1/D2' are re-assignments, not work.

Everything before B2 is collision-free with 2.3 and can proceed the moment the decision
checkpoint clears. B2 and B3 are the only items touching `lemon_channels` and must queue behind
2.3.

### What this does *not* deliver

`LemonGateway.Transport` and `TransportRegistry` survive 2.4, holding email and webhook. After
email ports, the registry has exactly one entry — at which point deleting
the behaviour and inlining the remaining transport's supervision is a trivial follow-up worth
doing for its own sake. That is the honest path to "one transport concept": shrink it to nothing
by attrition, then remove it, rather than forcing four bad ports to justify a deletion.

## 7a. Capability delegation — `LemonChannels.Capabilities` (addendum from 2.3 close-out)

### What exists today: three sources, two vocabularies

| Source | Shape | Owner | Used by |
|---|---|---|---|
| `Plugin.meta/0`'s `capabilities` map | snake_case flags + numbers: `edit_support`, `delete_support`, `thread_support`, `reaction_support`, `voice_support`, `image_support`, `file_support`, `chunk_limit`, `rate_limit` | each adapter (incl. the x_api satellite) | `Registry.get_capabilities/1` |
| `Capabilities.from_legacy/1` (`capabilities.ex:636`) | converts the above into the typed form | lemon_channels | `Registry.get_capabilities_new/1` → `supports?/3`, `supports_feature?/3`, `validate/3` |
| `Capabilities.Registry.lookup/1` (`capabilities.ex:282-346`) | **static, string-keyed table** hard-coding `"telegram"`, `"discord"`, `"x_api"`, `"xmtp"`, `"whatsapp"`; richer typed vocabulary: `:threads`, `:reactions`, `{:attachments, max_size:, features:}`, `{:rich_blocks, features:}`, `{:chunk_limit, value:}`, `{:rate_limit, value:}` | lemon_channels | `capability_query.ex:102`, `capabilities_test.exs` |

So capability data lives in **two independent places** with **two different vocabularies**, and
there is no mechanism keeping them in sync. `Registry.supports?/validate` read the *registered
adapter's* meta (via `from_legacy`); `Registry.lookup/1` reads the *static table*. Nothing
reconciles them.

### The concrete case: x_api's 280-char chunk limit

`chunk_limit: 280` is declared **twice**: `apps/x_api/lib/x_api/channel_adapter.ex:24` (the
satellite's own `meta/0`) and `apps/lemon_channels/lib/lemon_channels/capabilities.ex:320` (the
static table). `capabilities_test.exs:386-395` asserts against the *static* one, so the satellite
could change its real limit and the test would keep passing.

This is now a **D7 violation in substance**. D7 says the platform "loses all compile-time
knowledge of X", and 2.3 just moved the X adapter out to a satellite — but `lemon_channels` still
carries a hard-coded `lookup("x_api")` clause describing it. The satellite is no longer able to
be the source of truth about itself. The same will be true of any future satellite, and of email
once it ports.

Note also the vocabularies are not equivalent, so this is not a pure duplication: `from_legacy`
can express neither `max_size` for attachments (it only ever sets `features: [:images]`) nor
`rich_blocks` features nor `rate_limit`. The static table is strictly richer. Any delegation
must therefore *widen the meta contract*, not just redirect lookups — otherwise telegram/discord
silently lose `max_size`, `rich_blocks` features, and `rate_limit`.

### Outcome (2026-08-10): deleted, not delegated

Verifying the caller list before implementing changed the answer. `CapabilityQuery` aliases
`LemonChannels.Registry` — the *plugin* registry — not `Capabilities.Registry`, so it already
resolved through registered-adapter meta and already returned nil/false for unknown channels.
`Capabilities.Registry.lookup/1` had **zero production callers**; only its own test file
referenced it. The unconfigured-channel contract question was therefore moot: no caller could
observe either answer.

So `lookup/1` was deleted outright rather than repointed, `get_set/1` kept, the x_api assertions
moved to `apps/x_api/test/x_api/channel_adapter_test.exs` against the satellite's own `meta/0`,
and the `Plugin.meta/0` widening was **deferred** — see the Deferred section of
`platform-split.md`, which records the richer vocabulary the table carried so it isn't lost with
the code. Growing the platform's most third-party-facing extension point for data nobody reads
was the wrong trade.

The original delegation design is kept below for the day a real consumer appears.

### Recommended end state (superseded — retained for when a consumer needs the richer vocabulary)

Capability lookup delegates to the registered adapter; the static table is deleted.

1. **Widen `Plugin.meta/0`'s `capabilities` to the typed vocabulary** — accept the
   `Capability.spec()` list form (`[:threads, {:attachments, max_size: …}, {:chunk_limit, value: …}]`)
   that `Capabilities.new/1` already consumes. Keep `from_legacy/1` accepting the current flag map
   for one release so no adapter breaks on the day the contract widens.
2. **Make `Capabilities.Registry.lookup/1` resolve through the channels registry**: look up the
   registered plugin module for the id, call its `meta/0`, and build capabilities from that.
   Fall back to `Capabilities.empty()` for unknown ids exactly as today (`capabilities.ex:345`).
3. **Delete the five hard-coded clauses.** Each adapter's own `meta/0` becomes the single source
   of truth, and satellites self-describe — which is what D7 requires and what 2.3 assumed.
4. **Move the assertions.** `capabilities_test.exs`'s per-channel tests currently pin platform-side
   constants; they should either move next to each adapter (asserting *that adapter's* meta) or
   assert the delegation mechanism against a test double, not real channel constants. The x_api
   280 assertion in particular belongs in `apps/x_api`, not in `lemon_channels`.

### Why this belongs to 2.4 rather than 2.5

It is capability data flowing *from adapters into the platform*, which is the same direction as
the port itself, and it is a precondition for a ported email adapter to declare its own
attachment limits rather than having lemon_channels hard-code them. 2.5's `EngineInfoBridge` is
about the platform reading *gateway* state across an app boundary — related in spirit, different
data and different direction.

Sizing: step 1 **S**, step 2 **S**, steps 3–4 **M** (the test churn is the bulk). No collision
with 2.2. It does touch `lemon_channels/capabilities.ex` and the x_api adapter, so it should land
after 2.3 — which is now complete, so this is unblocked.

**Caveat worth deciding explicitly:** delegation makes capability lookup depend on a plugin being
*registered at runtime*. Today `lookup("telegram")` answers correctly even if Telegram was never
started. If any caller relies on that — asking about a channel that isn't configured — delegation
changes behaviour from "static answer" to "empty". `capability_query.ex:102` is the one
non-test caller to check before implementing.

## 7b. B3 handoff — outbound + cutover (for the next worker)

**What landed (B3 inbound-only, 2026-08-10).** `LemonChannels.Adapters.Email` implements
`Plugin`'s six callbacks and normalizes provider webhook payloads into
`LemonCore.InboundMessage`, with `LemonChannels.Adapters.Email.Webhook` receiving on
`LemonChannels.InboundHttp` at `POST /email` (token-authenticated, 401 when no token is
configured — an open inbound mail endpoint is a spam relay into someone's agent). 17 tests.

**Nothing has cut over.** `LemonGateway.Transports.Email` is still registered and untouched, the
channels adapter is *not* in `config :lemon_channels, adapters:`, and `InboundHttp` is disabled
by default. Three independent gates, so this is inert in every existing runtime.

**Status 2026-08-10: complete. All four items landed; email is a channel and the gateway
transport is deleted.**

1. **Outbound — done.** `LemonChannels.Adapters.Email.Outbound` sends over SMTP.
   `smtp_options/1` moved across unchanged and its 22 characterization tests were carried over
   verbatim into `apps/lemon_channels/test/lemon_channels/adapters/email/outbound_test.exs`; all
   pass, so the configuration semantics are provably identical. Two behaviours did *not* survive,
   both because they described the old entrypoint rather than email:
   - the `job.meta` guard that made `deliver/2` a silent no-op for non-email runs — `deliver/1`
     is only ever called for its own channel, so an unsendable payload is now an `{:error, _}`
     rather than a swallowed `:ok`;
   - the "Attachment references" block appended to the body from the run's output files — in this
     pipeline a file is its own `:file` payload with the file attached, so there is nothing to
     reference.

   The gateway version read its reply headers from `job.meta.email_reply`, which
   `OutboundPayload` has no equivalent of. That is what forced the decision below.

2. **Thread-state persistence — decided: port the tables.** `LemonChannels.Adapters.Email.ThreadStore`
   keeps `:email_message_threads` and `:email_thread_state` in `LemonCore.Store`, table names and
   shapes unchanged so existing threads survive the cutover. Two reasons, either sufficient:

   - **Outbound has nowhere else to get its headers.** `OutboundPayload` carries the recipient, a
     thread id and a `reply_to`, but no `Subject` and no `References` chain — and should not,
     since neither means anything to a channel that is not email. Without stored state a reply
     invents a subject and sends an empty `References`, which is the difference between landing
     inside the recipient's conversation and starting a new one. This alone settles it; the
     stateless option was only ever viable for an inbound-only adapter.
   - **The middle-message gap is real and cheap to close.** Recording `message id → thread id` as
     messages arrive means any later message naming *any* known ancestor joins the existing
     thread. `apps/lemon_channels/test/lemon_channels/adapters/email/thread_store_test.exs` has
     the case as an executable test.

   `thread_id/1` stays pure and stateless as the seed; `ThreadStore.resolve/2` layers the lookup
   in front of it. So the store is an optimisation over a correct-by-default computation, not a
   dependency: with no store running, reads answer `nil`, writes answer `{:error,
   :store_unavailable}`, neither raises, and the adapter behaves exactly as it did before.

3. **Attachments — done.** `LemonChannels.Adapters.Email.Attachments` prepares metadata on the
   request path and defers the writes, same shape as the gateway's: deterministic paths, 10 MB
   cap, sanitized filenames, 0600 on Unix, multipart `Plug.Upload` copied off Plug's temp file,
   URL-only attachments passed through undownloaded. One addition the port needed: the channels
   prompt is `message.text` and nothing else (`RunRequestBuilder`), so the attachment lines are
   appended to the text — the gateway put them in a prompt it built itself.

4. **Cutover — done.** `email` joined `discord` in `TransportRegistry`'s
   `@channels_owned_transport_ids`, its `enable_email` gate and dual-gate warning are gone, the
   adapter is in `config :lemon_channels, :adapters`, and
   `apps/lemon_gateway/lib/lemon_gateway/transports/email{,.ex}` plus its tests are deleted.
   `gen_smtp` and `mail` are no longer gateway dependencies — the email transport was their only
   consumer there, verified by grep before removal.

   **Inbound stays off by default**, deliberately. The gateway transport being replaced was
   itself dead-by-default behind `:gateway_ingress_enabled`, so preserving that posture is what
   makes this a move rather than a feature launch: the adapter registers (its `start_link/0`
   returns `:ignore`, so it occupies no process), outbound is fully live once a relay is
   configured, and *receiving* mail waits on a host explicitly enabling
   `LemonChannels.InboundHttp` and setting a webhook token. Verified at boot: email is in the
   registry, `InboundHttp.enabled?/0` is false, no Bandit child is running, and `deliver/1`
   answers `{:error, :missing_smtp_relay}` rather than pretending. The enablement recipe is in
   `LemonChannels.Adapters.Email`'s moduledoc.

   One gateway test lost its subject: `LemonGateway.ConfigLoaderTest` asserted that the TOML
   `email` block fed `smtp_options/1` correctly. Gateway must not reach across to
   `lemon_channels` (see §8's risk about exactly that edge), so the loader test now asserts only
   what the loader produces, and the consumer assertions moved to the channels outbound test with
   the same fixture.

**Config continuity.** `LemonChannels.Adapters.Email.Config` reads
`config :lemon_channels, LemonChannels.Adapters.Email` *and* the canonical TOML `[gateway]`
config's `email` block, application env winning. A deployment configured while email lived in the
gateway therefore keeps its relay, sender and webhook token across the cutover without editing
anything.

**Hardening that came with the port.** Four things, three of which outlived the email adapter:

- **`normalize_inbound/1` raised on hostile input**, violating the one `Plugin` rule the platform
  cannot enforce. `subject[]=a&subject[]=b` through `Plug.Parsers`' urlencoded parser puts a
  *list* in a string field; the adapter reached for `String.replace/4` and crashed, on four
  fields. Non-binaries are now treated as absent — picking an element or stringifying would
  invent a message the sender did not send. `LemonPlatformTest.PluginCase`'s hostile-input list
  grew four entries of this class so every adapter is probed, which immediately caught the same
  bug in Telegram (`message["text"]` as a list travelled all the way into `InboundMessage.text`).
- **Authentication now runs before parsing.** `LemonChannels.InboundHttp.Handler` gained an
  optional `authorized?/1` that the router calls between `:match` and `Plug.Parsers`, so an
  unauthenticated caller can no longer make the listener decode a body before its 401. Handlers
  that verify a signature over the body omit it and are unaffected.
- **The body limit is configurable and coherent with attachments.**
  `InboundHttp.max_body_bytes/0` (2 MB default, read per request rather than frozen into the plug
  pipeline at compile time), and the email attachment cap now *derives* from it — three quarters,
  since attachments arrive base64-encoded and inflate by about a third. A cap larger than the
  body limit was unreachable, and the two can no longer be configured into contradiction.
- **An unreachable router produces a truthful ambiguous receipt.** A mutation exception or exit
  may occur after the router accepted the run, so `RouterBridge` classifies it as
  `{:error, :outcome_unknown}` rather than definite unavailability. The email webhook durably
  retains the fixed Message-ID/run reservation and answers 200 `outcome unknown`, preventing a
  provider retry from duplicating work. Failures before a durable idempotency reservation exists
  still return 503 and ask the provider to redeliver. Email replay content hashes upload bytes
  rather than provider-generated temporary paths, and exact webhook response receipts are removed
  with their completed primary reservations after the fixed 24-hour replay horizon. Caller webhook
  idempotency keys are domain-separated and hashed before they enter any durable key, receipt, or
  run metadata; cleanup commits atomically on SQLite and preserves the primary execution fence on
  any ordered-backend failure. Upgrade migration creates the hashed fence and exact response before
  conditionally removing legacy raw-key records, accepts only non-empty binary keys, and treats
  incomplete cleanup scans as unavailable without advancing their schedule.

**Contract kit.** `apps/lemon_platform_test/test/compliance/email_plugin_test.exs` relied on
`deliver/1` being inert. Its probe is now a `:reaction` payload — a kind email has no concept of,
refused before any configuration is read — so the probe stays side-effect-free regardless of what
relay the host running the suite has configured.

**Do not** take this as licence to port webhook/SMS/voice — §1 and the amended D2 still hold.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Email's 715-LOC untested `outbound.ex` regresses during the port | B1 first, no exceptions — characterize before moving |
| `lemon_channels` gaining `plug`/`bandit` bloats a to-be-published package | They are genuine runtime deps of an inbound adapter; if that is unacceptable, mark them optional and have the email adapter degrade like `exqlite` does in lemon_core (precedent: task #13 — and declare them properly in `extra_applications`, per the Mix code-path-pruning trap that bit `LemonCore.Httpc`) |
| Someone "finishes" 2.4 by force-porting webhook/voice to hit the D2 wording | A2 amends D2 in writing before any code moves |
| gateway ⇄ channels direct dependency gets added as a shortcut during B3 | Extend the architecture check to fail on that edge (it does not exist today) — cheap, and this migration is exactly the scenario that would tempt it |
