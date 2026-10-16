# LemonChannels contributor guide

Channels owns external messaging adapters, authorization/normalization, platform
rendering and the delivery outbox. Router owns conversation semantics and prompt
mutation; gateway owns execution slots. See [README](README.md) for adapter setup
and script notifications.

## App seams

- Normalize inbound traffic into core contracts and submit through
  `LemonCore.RouterBridge`. Preserve success, rejection and unknown-outcome
  distinctions. Never acknowledge rejected work or automatically retry an
  ambiguous mutation; busy-query failure is not idle.
- Router emits `LemonCore.DeliveryIntent`. Channels owns `OutboundPayload`,
  send/edit, chunking, buttons, media batching and platform message indices.
- Resolve project/agent/cwd/queue bindings through `LemonCore.BindingResolver`.
  Bindings never select an executor. Native `lemon` tokens alone resume top-level
  work; old vendor tokens remain readable history but never select a runtime.
- Use `TargetDirectory` as the cross-app target-discovery seam. Other apps should
  not read Telegram/Discord known-target tables directly.
- Adapters run under `AdapterSupervisor` from the configured adapter list. Do not
  add hardcoded platform startup gates to the application supervisor.
- Each platform config implements `LemonCore.Config.Gateway.Channel`, registers
  under `:gateway_channels`, and owns its env declarations. Production transport
  settings come from canonical TOML via `GatewayConfig`, not app-env overlays.
  The full-replacement test config layer is for isolation only.

## Authorization

- Telegram authorization applies to messages and callback queries. A non-empty
  `allowed_chat_ids` is authoritative; an empty allowlist is unpaired and drops
  updates unless `allow_all_chats: true` is explicit. `/whoami` may answer before
  auth; unpaired notices are throttled. Transcription runs only after auth.
- Transports read the persisted gateway allowlist on every (re)start; supervisor
  child specs must not freeze it. Pairing approval/revocation go through
  `LemonChannels.Pairing.allow/2` / `revoke/2` (a `:update_allowlist` call to the
  transport) so running transports update live; never require a restart or widen
  beyond the named chat. A configured empty Discord `allowed_channel_ids` is
  deny-all; only an absent key is unrestricted.
- Discord slash commands must pass the same guild/channel allowlists and
  `deny_unbound_channels` checks as ordinary messages before any read, mutation,
  cancellation, reflection or runtime call.
- Group/supergroup/channel trigger mode defaults to mentions. Keep topic/thread
  scope in auth, bindings, delivery and state keys.
- Diagnostics and notification JSON expose bounded metadata, not credentials,
  message bodies, attachment paths or raw platform responses.

## Delivery and state

- Outbox FIFO grouping includes channel, account, peer kind/id and thread.
  Preserve order within a group while allowing independent groups to progress.
- Outbox delivery is at-least-once for the channels whose adapters report an unknown outcome. An unknown outcome
  (adapter `{:outcome_unknown, _}`, adapter exception, worker exit) is retried
  with the same payload and idempotency key within the bounded `max_attempts`
  budget, then reported terminal. This is the one deliberate exception to the
  root never-retry `:outcome_unknown` rule: a rare duplicate message is cheaper
  than a lost one, and sending is not a state mutation to reconcile. Dedupe is
  marked only on confirmed delivery and still suppresses re-sends of confirmed
  keys, including pending retries. Adapters keep returning ambiguous writes as
  `{:outcome_unknown, _}` and never retry them internally; the outbox owns that
  retry. Unrecognized errors and definite rejections stay terminal, and the
  exception covers no other mutation (inbound submission, enqueue timeouts).
  `DeliveryError.outcome_unknown?/1` is the one classifier of what counts as
  unknown; `outbox_adapter_contract_test.exs` asserts every built-in adapter
  normalizes its ambiguous sends to it, so a new adapter extends that test.
  Return unknown only where the message may already have been accepted: an SMTP
  connection lost once DATA was issued and a WhatsApp bridge `sendMessage`
  exception (flagged `outcome_unknown` by the bridge) are unknown; SMTP
  rejections, a connection lost before DATA, and a WhatsApp failure before the
  send call (not connected, unreadable media) stay terminal.
  Honor rate-limit hints.
- Telegram markdown entity offsets are UTF-16, not bytes/graphemes. Truncation
  must preserve native resume lines and table column boundaries.
- Transport GenServers remain lifecycle shells; add behavior to existing local
  normalization/pipeline/command/action helpers. Async Telegram work uses its
  task supervisor. Picker/system traffic should use the delivery/outbox path.
- `/model` scope is deliberate: session choices stay session-local, while
  future-session defaults are chat-wide even when selected from a topic. Accept
  exact labels and plain provider/model IDs; selections are not ordinary prompts.
- `/new` increments `{account, chat, thread}` generation before new mappings.
  Session/resume keys include generation and message ID, invalidating old replies
  without full scans. Abort/cleanup/reflection is background work; reflection
  ambiguity is logged safely and not retried automatically.
- Known-target writes are throttled unless metadata changes. Use the app-owned
  wrapper rather than bypassing its policy.
- Generated media is opt-in, count/size bounded and cwd/symlink checked upstream.
  Rendering must not expose host-only `MEDIA:` directive lines.
- XMTP and WhatsApp retain separate process identities/scripts/event tags while
  sharing `PortBridge` lifecycle mechanics. A stopped port must not leave its
  child or stale reconnect state alive.

## Operator paths and verification

`lemon send` / `./bin/lemon send` support Telegram and Discord. Keep
[script notification usage](README.md#script-notifications) authoritative for
account/thread defaults, stdin, attachments, dry-run, JSON and exit codes.
`mix lemon.channels` inspects redacted configuration; `lemon doctor` reports
configuration health, not a stored live-proof gate.

From the umbrella root: `mix test apps/lemon_channels/test`.
Use local/fake platform APIs; exercise unauthorized callbacks/slash commands,
thread isolation, outbox order, retry boundaries, Unicode entity offsets and
restart cleanup. Tests changing global runtime apps restore their original
running set and do not stop unrelated consumers.
