# LemonChannels contributor guide

Channels owns external messaging adapters, authorization/normalization, platform
rendering and the delivery outbox. Router owns conversation semantics, prompt
mutation and execution slots. See [README](README.md) for adapter setup
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
- Discord slash commands and message components (cancel, keep-alive, model)
  must pass the same guild/channel allowlists and `deny_unbound_channels`
  checks as ordinary messages before any read, mutation, cancellation,
  reflection or runtime call. Run-control components act only on the active
  run of the clicker's own session. `adminOnly` catalog entries are enforced by
  `LemonChannels.CommandAuthority`, not just hidden.
- Discord `/resume` selections are keyed by the selecting user's full session
  key and cleared by `/new`/`/reset`.
- Chat `/file` and `/cwd` go through `LemonCore.FileAccess` and
  `LemonChannels.ProjectSelection`: physical-root containment with no symlinks
  below the root, case-insensitive built-in secret denies and `deny_globs`
  judged on actual entry names (malformed globs deny everything), configured
  project ids only. The gateway send-file tools use the same module and queue
  a private copy, never the source path.
- XMTP authorizes the MLS-authenticated sender inbox id against
  `gateway.xmtp.allowed_inboxes`, re-read from current config per message,
  before dedupe, placeholder replies or submission; empty is deny-all unless
  `allow_all: true`. Group messages also need an `@` mention of the bot inbox
  id or wallet. The bridge never syncs, lists or streams DENIED-consent
  conversations and re-checks consent immediately before every send.
- The email webhook authorizes the parsed `From` mailbox with
  `Email.SenderAuth` (`gateway.email.inbound.allowed_senders`, empty is
  deny-all; a passing provider `Authentication-Results` verdict pinned by
  `authserv_id` is required, and no `authserv_id` is deny-all unless the
  documented, startup-warned `sender_auth = "from_only_unsafe"` opt-out is
  set; `dmarc=fail` always refused), re-read per request, and answers 403
  before `normalize_inbound/1`, thread/attachment writes, reservation or
  submission. Email prompts stay fenced with `ExternalContent` (source
  `:email`); never hand the router unfenced sender text.
- Email `ThreadStore` rows are keyed by `{inbox, sender, id}` on inbound and
  outbound paths; never read unscoped (legacy) rows. Every email address
  (sender, recipient, inbox, From/Reply-To config) goes through
  `Email.Address.parse/1`, the one whole-mailbox parser; never extract a
  substring or approximate an address it refuses. Outbound headers take only
  single-line values: unfold, refuse control characters, and keep only
  `MessageId.valid?/1` ids.
- Group/supergroup/channel trigger mode defaults to mentions. Keep topic/thread
  scope in auth, bindings, delivery and state keys.
- Diagnostics and notification JSON expose bounded metadata, not credentials,
  message bodies, attachment paths or raw platform responses.

## Delivery and state

- Outbox FIFO grouping includes channel, account, peer kind/id and thread.
  Preserve order within a group while allowing independent groups to progress.
- Acknowledged outbox admission crosses the Store durability barrier. Reload
  pending records with their original keys, retry budget and FIFO sequence;
  remove payload content only after a durable terminal transition. Pending
  capacity includes admissions waiting for storage. Keep Store barriers off the
  queue owner, lookup/check paths process-call-free, and delivery tasks capped.
  Durable retry/expiry stamps use wall time; volatile dedupe/rate buckets use
  monotonic time. Production recovery requires a persistent Store backend.
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
  Telegram long polls run in `AsyncSupervisor` via `async_nolink`; apply replies
  to current transport state, never overwrite live allowlist/drain changes with
  a task's old snapshot. Drain discards an in-flight batch without confirming
  its offset. Bootstrap probes and token-scoped service-lock acquisition happen
  in `handle_continue`, not `init`. Missing supervision fails closed.
  Outbound sends never sleep or retry; the outbox owns transient/rate-limit
  retry budgets and backoff, including media sends.
- `/model` scope is deliberate: session choices stay session-local, while
  future-session defaults are chat-wide even when selected from a topic. Accept
  exact labels and plain provider/model IDs; selections are not ordinary prompts.
  A reply-keyboard picker answers only its opener, after the trigger gate, and
  expires when idle.
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
