# Changelog

All notable changes to Lemon are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [CalVer](https://calver.org/) — `YYYY.MM.PATCH`.

---

## [Unreleased]

### Fixed

- Hermes skill install/update requests no longer block their own control-plane
  WebSocket while waiting for approval or Git work. Approval events and
  liveness probes remain deliverable, and the TUI keeps the correlated skill
  mutation request open long enough for human approval and installation.
- Hermes imports now report security-audit refusals directly, and escaped
  Markdown examples such as `curl ... \\| bash` no longer trigger the
  executable-pipeline rule. Real unescaped remote-script pipelines remain hard
  blocks, but operators can accept an exact audited bundle through a separate,
  conspicuous security-override approval that cannot be satisfied by ordinary
  install approval or reused after content changes.
- Telegram, Discord, and WhatsApp tool-status bubbles now omit fixed internal
  engine provenance and reasoning-only actions, so step counts reflect
  user-relevant tools. Automatic filesystem checkpoint lifecycle events remain
  auditable internally and available through explicit `/checkpoint` and
  `/rollback` commands without being pushed into ordinary channel chats.
- Source `./bin/lemon` now detects and reuses a healthy local control plane
  before compilation or Erlang distribution startup, so invoking it beside an
  existing runtime no longer fails with a duplicate `lemon@host` node name.
  Web health probes tolerate bounded slow responses and trailing whitespace,
  and the quality lane exercises both direct-launch and `web --no-open` reuse.

### Added

- `LemonCore.Store.Table` ownership metadata for incremental generic-store
  migrations. The architecture gate now analyzes generic Store calls from the
  AST across every supported operation and default/explicit server arity,
  resolving aliases and module attributes and rejecting dynamic or cross-table
  access from an owner module. The metadata is non-operational in this change;
  backend registration, retention, and domain migrations remain separate.
- `LemonCore.PolicyStore` now declares the four existing policy tables it owns.
  This is metadata-only; policy access still uses the specialized Store API and
  its public functions are unchanged.

- Persistent source and packaged launchers now provision a private,
  port-scoped control-plane operator credential under `~/.lemon/run`, allowing
  later TUI processes to attach automatically without exposing the bearer in
  argv or enabling tokenless loopback access. Explicit operator tokens remain
  caller-managed and are never persisted by this handoff.

- Bidirectional A2A v1.0 peer interoperability for durable Lemon-Hermes
  conversations: Agent Card discovery, authenticated JSON-RPC and SSE,
  persistent context/session mapping, peer-scoped task lifecycle and
  cancellation, untrusted-content boundaries, and a built-in `peer` tool that
  resumes one long-running default conversation per configured agent.

- Bun TUI portable-blueprint management over the authenticated shared catalog:
  content-free `/blueprints` browsing and `/blueprint` inspect/validate/preview,
  exact fresh-digest activation, stale/refused-plan clearing with preserved
  profile drafts, nonqueueable offline mutation, and duplicate-safe replay.
  The terminal retains and renders only bounded IDs, counts, actions, booleans,
  and digests; real Bandit/Bun proof verifies planted manifest prose, prompts,
  skill bodies, commands, environment values, paths, tokens, and secrets stay
  out of terminal state and proof output.
- Token-required Web durable-memory management at `/manage/memory`, backed by
  a shared `LemonMemory.Lifecycle` over the canonical SQLite/FTS store. The
  responsive browser supports bounded search and safe scope/agent/workspace
  digest/kind filters, Safety-redacted run and learned-source previews,
  digest-only provenance, and exact single-record delete preview/confirmation.
  Deletion binds the document ID to a deterministic revision of every
  persisted field, compares it in constant time inside the same transaction
  that removes the document and FTS row, and fails stale/forged/malformed
  requests without mutation. Memory updates now replace their prior FTS row,
  preventing duplicate search hits for an updated document ID.

- Source and packaged `lemon learn` plus authenticated `learn.review` /
  `learn.confirm` control-plane methods for auditable learning from existing
  bounded file, folder, URL, diff, document, and redacted-session references.
  Review is non-mutating and content-free; confirmation is bound to an exact
  fresh digest and writes only canonical durable memory plus an audited skill
  draft, with traversal/SSRF defenses, redaction, collision checks, and
  idempotent re-review. Exact create-if-absent writes prevent stale destination
  overwrites, provenance-bearing records remain removable through their
  existing stores, and selected source content never enters LLM audit.

- Registry-driven source/packaged `lemon update check|plan|apply|history|rollback`
  with non-mutating manifest/current-bound plans, exact fresh-digest apply,
  serialized checksum/size-authenticated staging, pre-extraction archive
  confinement, verified private checkpoints, atomic pointer recovery,
  content-free receipts, and exact receipt/digest rollback. Source checkouts
  keep binary mutation fail-closed; schema-2 publisher-signing and exact
  in-flight `:httpc` byte cancellation remain explicitly documented residuals.
- Explicitly enabled, read-only 1Password, Bitwarden Secrets Manager, and
  argv-only command secret sources integrated behind the encrypted Lemon store,
  with exact schema validation, supervised time/output bounds, minimal child
  environments, fail-closed fallback behavior, optional bounded in-memory
  caching, and source/packaged `lemon secrets sources status|test` diagnostics
  that expose readiness/provenance only.
- Source and packaged `lemon blueprints` catalog list, sanitized inspect and
  validate, non-mutating default preview, and exact-digest activation over the
  existing authenticated control-plane/`CronManager` path, with stable redacted
  JSON/exit codes, registry-driven help/completion, duplicate-safe results, and
  real source plus assembled minimal-runtime proof.
- Token-required Web blueprint management at `/manage/blueprints`, backed by
  the shared `LemonAutomation.Blueprint.Catalog` service. The responsive page
  lists only safe IDs/counts, validates bundles, previews profile-local skill
  and schedule actions without mutation, requires the exact fresh digest, and
  reports create-once or unchanged replay without retaining manifest prose,
  prompts, skill bodies, paths, commands, environment values, or secrets.
- Authenticated Web provider-routing management at `/manage/providers`, with
  redacted effective status, ordered fallback controls, credential-pool and
  credential-reference lifecycle, preview-first writes, exact confirmation for
  destructive changes, and stale-preview rejection through opaque config
  revisions. Credential references are password-masked, filtered from logs,
  re-entered for apply, and never retained or rendered by the LiveView.
- Source and packaged `lemon sessions` commands for bounded list/search/show,
  exact redacted aggregate statistics with capped agent/origin breakdowns,
  and redacted history, title/pin/archive lifecycle, always-redacted
  JSON/Markdown export, exact-candidate preview-confirm prune, and verified
  exact-key delete; plus registry-generated `lemon completion bash|zsh|fish`
  scripts that preserve source and release launcher-specific commands.
- Bun TUI session lifecycle parity over the same authenticated control-plane
  service: live `/sessions` search/filter/picker UX; `/session` inspect, resume,
  title, pin, archive, redacted preview/export, exact-candidate guarded prune,
  and verified export-before-delete. Destructive mutations are never queued
  offline, refused/stale results do not discard drafts, and list/status/error
  rendering omits paths, prompts, credentials, and unredacted content.
- Source and packaged `lemon providers` readiness and routing management with
  comment-preserving fallback and credential-pool reference edits, stable
  redacted JSON/exit codes, exact confirmation for destructive changes, and a
  matching admin-scoped `providers.configure` control-plane method.
- A client-independent `LemonCore.Context` preview/resolve contract and
  packaged `lemon context` command for bounded `@file`, `@folder`, `@git-diff`,
  `@url`, and redacted `@session` references. PDF, DOCX, XLSX, PPTX, notebook,
  and text content is format-sniffed with explicit byte/page/item/depth/time
  limits, archive-bomb/traversal and symlink defenses, SSRF-safe pinned URL
  fetching, sensitive-value redaction, and structured omission metadata.
- Versioned portable skill + automation bundles with bounded manifest and
  filesystem policy, deterministic source-and-stage audit, profile-local skill
  enablement, content-free control-plane list/inspect/validate/preview, exact
  digest confirmation, and create-once idempotent cron activation.
- An authenticated Lemon Web session-management shell with runtime and live-node
  status, durable search/resume, title/pin/archive controls, redacted structured
  run/tool inspection, bounded JSON/Markdown export, and exact-candidate guarded
  prune. Query-token bootstrap redirects server-side to a clean URL before
  rendering, and named chat routes reconstruct durable history before resuming.
- A shared `LemonCore.SessionLifecycle` service and control-plane
  `sessions.metadata.patch`, `sessions.export`, and `sessions.prune` methods.
  Export fails closed against raw run/event payloads and secrets; prune commits
  canonical history last, verifies deletion, and binds confirmation to exact
  parameters and stable candidate state.
- Source and packaged `lemon backup contract|create|list|verify|restore`
  commands backed by a versioned `~/.lemon` data contract, atomic private
  directory bundles, exact file-set and SHA-256 verification, credential
  exclusions, permission-widening rejection, target-bound overwrite
  confirmation, staged restore, rollback receipts, stable JSON, and documented
  exit codes.
- First-class user-managed profiles over the existing router agent plane, with
  atomic/comment-preserving create, list, show, clone, rename, credential-safe
  export, and guarded recoverable delete; isolated profile workspaces for
  bootstrap/memory/skills; stable `agent:<id>:main` chats; node-aware rosters;
  packaged `lemon profile` commands; matching control-plane methods; and TUI
  `/profiles` roster/picker plus `/profile` inspection, canonical-chat, and
  guarded lifecycle commands. Normal TUI prompts in an opened profile route
  through `profile.chat`, preserving derived workspaces and named nodes. The
  authenticated Web shell now adds a responsive `/manage/profiles` roster and
  preview-first create/clone/rename/recoverable-delete journey with stale
  revision refusal, exact delete confirmation, canonical-chat links, and no
  profile paths or system prompts retained in LiveView state.
- `lemon web [--no-open]` in source and full packaged launchers, with daemon
  auto-start, exact Web health polling, browser opening, and actionable profile
  or startup errors.
- A shared `LemonCore.Setup.Readiness` contract plus a fail-closed Web first-run
  guide, live config/secret refresh, active-run stop control, and accessible
  responsive status/composer states.
- Durable same-session heartbeats with idle-only recurring turns, queued-user
  priority, missed-tick coalescing, pause/resume/clear lifecycle, restart-safe
  fire claims, reset tombstones, logical session-key resolution, an admin
  `sessions.heartbeat` API, and TUI `/heartbeat`/`/hb` commands.
- Portable Hermes-compatible slash-command discovery metadata for channel and
  interactive clients, exposed through the read-only `commands.catalog`
  control-plane method while preserving Lemon's router/session ownership and
  active-run-only `/stop` semantics.
- End-to-end Hermes-compatible `/queue`/`/q`, `/steer`, `/reset`, `/reasoning`,
  `/stop`, `/status`, `/usage`, `/agents`/`/tasks`, `/compress`, `/commands`,
  `/help`, `/bg`, and `/btw` support across Telegram, Discord, the TUI, and the
  control plane. Background runs are isolated full-tool sessions; side
  questions use bounded no-tools transcript snapshots without changing parent
  history.
- Channel `/bg` receipts now retain the complete durable job id and Telegram and
  Discord expose `/bg list`, `/bg status <id>`, `/bg result <id>`, and `/bg
  cancel <id>`. Discord portable slash commands also enforce configured
  guild/channel and binding policy before execution, and channel command errors
  no longer render arbitrary internal runtime reasons. Background lifecycle
  access is scoped to its originating channel session so foreign ids are hidden
  as not found, and Discord now applies the same policy gate to every application
  command before reset/reasoning/cancel or other command dispatch.
- Hermes-compatible `/bg` backend sessions with durable lifecycle ids,
  isolated full-tool execution, status/result/list/cancel APIs, and
  restart-safe lost-run reporting; plus bounded `/btw` no-tools queries over
  immutable live snapshots or durable channel session-key history without
  mutating the parent conversation.
- Extensible capability-aware web search/extraction providers with deterministic
  fallback, provider isolation, request-level selection, extension registration,
  keyless DuckDuckGo, configurable SearXNG, Exa search/highlights and batch
  contents extraction, and concurrent
  single-flight request coalescing
- Backend-neutral multi-tab browser control with stable target IDs, safe
  attached-browser lifecycle semantics, authenticated single-use controller
  tickets, and a bundled token-gated Manifest V3 relay for existing signed-in
  Chrome tabs
- Hosted browser lifecycle adapters for Browserbase, Browser Use Cloud,
  Firecrawl, and Camofox; explicit public/local hybrid routing; bounded
  `browser_exec` programs with developer-gated raw CDP; and cross-platform
  `computer_use` backed by exact-session cua-driver state
- Redaction-safe live leadership acceptance harnesses covering real
  `gpt-5.6-luna`/`xhigh` search fallback, multi-source synthesis, multi-tab and
  stale-target browser control, screenshot analysis, extension relay ownership,
  and fail-closed controller consent boundaries
- Named execution nodes can now pair with a Lemon controller through
  `./bin/lemon node join`, advertise live presence under a unique name, and
  run native delegated `CodingAgent.Session` work selected by the `agent`
  tool's `node` parameter. Pairing persists a private, controller-bound token
  on the destination machine; remote runs keep credentials and default working
  directories destination-local and support targeted cancellation plus
  invocation-bound steer/redirect with authenticated destination
  acknowledgement and fail-closed terminal races.
- The control-plane chat surfaces and TUI now preserve redirect as a distinct
  active-run mode. The TUI exposes `/redirect` and cycles queue, steer,
  redirect, and interrupt without conflating redirect with non-canceling steer.
- Lemon Web now discovers an already-active session run and presents explicit,
  responsive follow-up, steer, and redirect choices. The text-only controls
  recheck run eligibility at submit time, keep stop bound to the real active
  run, preserve a refused draft, and report bounded user-facing outcomes
  without rendering internal node/runtime errors.

### Changed

- `execute_code` gained an explicit result channel: `text()` blocks are the tool
  result (write-through flushed per call, so they survive a timeout/abort kill),
  while stdout/stderr is demoted to a clearly labeled diagnostics tail. Scripts
  that never call `text()` keep the historic stdout-only result byte-for-byte.
  New knobs: `max_text_bytes` (text budget, default 64 KiB) and
  `max_parallel_rpc` (pump dispatch concurrency, default 4).
- `execute_code` result-channel hardening (fix round): the `text()` budget now
  charges the JSON-encoded frame, so NUL-heavy strings that expand six-fold
  under escaping are refused on the script side instead of being written and
  silently dropped by the host; persistent kernels reset the per-cell bridge
  (fresh text budget, fresh counters) and refuse calls from threads stamped
  with an earlier cell; `notify()` caps are per run across sweeps, malformed
  frames are no longer forwarded or counted, and a final notification drain
  forwards a `notify()` issued immediately before exit; claimed RPC requests
  always end answered (a killed sweep leaves in-flight claim markers that the
  successor sweep or the cancel path answers in writing, reconstructing the
  call accounting), and an approval prompt left pending by a killed dispatch
  is cancelled, so it can never be approved into policy after the script died.
- `execute_code` result-channel adversarial hardening (fix round 2): RPC
  dispatch is now gated on publishing a regular-file claim marker (a planted
  object at the marker name or a symlinked request is answered with an error
  and never dispatched), recovery trusts only regular-file markers (planted
  directories are ignored, never charged) and restores the real accounting
  beside an already-published successful response, marker deletion failures
  can never re-charge the budget on a later sweep, and approval cancel/resolve
  is one atomic store transition (`LemonCore.ExecApprovals.cancel/2` and
  `resolve/2` now return `{:error, :not_pending}` to the loser) with the
  dispatch watcher cancelling after each owner death so a prompt registered
  after its sweep died cannot be orphaned; a killed sweep's lost accounting
  is flagged (`rpc_accounting_loss`) and forces the result to `:untrusted`;
  persistent-cell thread quarantine now stamps threads with their creator's
  cell generation at construction time, so a stale thread's descendants stay
  stale; the `text()` host-side budget charges the encoded frame (identical
  to the shim) and the shim normalizes lone surrogates, so an in-budget
  block is always delivered.
- `execute_code` result-channel hardening (fix round 4): a sweep caught
  raising or throwing mid-flight is still contained (the server stays
  alive) but no longer reported as if it had merely kept its old stats —
  it settles through the same recovery-plus-`rpc_accounting_loss` path as
  an abnormal death, so claims it dispatched are answered and charged from
  the host-side claim ledger and surviving responses instead of being
  silently discarded; claim recovery takes the tool identity from the
  host-owned ledger whenever both ledger and script-writable marker exist,
  so overwriting a marker body can no longer forge the recorded tool; and
  a successful cancel folds the sweep's still-queued claim-ledger messages
  through the same deduplicating recovery instead of reinserting them as
  stale ledger entries.
- `execute_code` result-channel hardening (fix round 5): the persistent
  server's claim ledger now records a reservation entry the moment a
  request spends its `max_calls` slot — refined by its disposition
  (`:invalid`, `:unknown_tool`, `:denied` when answered without dispatch,
  `:claimed` for dispatch-bound requests) — and sweep-failure settlement
  re-applies reserved entries exactly (one call, one error or denial, the
  replay memory, no response writes), so a contained fault after an
  answered-but-never-dispatched request can no longer erase that spend and
  let resumed sweeps exceed the call budget.
- `execute_code` scripts gained `notify(msg)` — a streaming side channel whose
  messages are forwarded to the tool's partial-update callback (capped at 4 KiB
  per message, 64 per run) — and `batch([...])`, which runs helper calls in
  parallel through the pump's bounded wave dispatch with exact call-limit,
  replay, and byte-budget accounting.


- Packaged and Mix `secrets check` output now reports only `present` and source
  category counts; it no longer reveals credential prefixes or suffixes.
- Lemon Web now ships compiled CSS inside the release instead of loading
  Tailwind from a runtime CDN, so the local chat shell works offline.
- Vendored Phoenix and LiveView browser clients now match the locked server
  dependencies, removing the live asset-version mismatch warning.
- Lemon Web declares and serves a bundled favicon instead of logging a missing
  route on each new browser session.
- Background and side-query public APIs now use stable content-free failure
  classifications; their control-plane RPCs allowlist lifecycle fields and
  return fixed bounded error codes/messages without provider terms, persisted
  errors, filesystem paths, or credential details.
- Background and durable side-query launches now normalize string-valued
  reasoning policy to the native atom contract before provider execution.
- Packaged and Mix secrets check/import commands now share one ordered
  environment-credential catalog instead of maintaining three copies
- LemonSim scenarios now share one bounded model/provider/credential resolver;
  unknown provider input no longer creates BEAM atoms, while scenario-specific
  setup errors and provider aliases remain intact
- LemonSim Mix tasks now share ordinary runtime, option, and bounded
  provider/model helpers instead of maintaining two dozen private copies;
  arbitrary provider CLI input no longer creates atoms
- Fifteen LemonSim scenario logs now share one JSONL lifecycle and encoding
  implementation while retaining their existing public APIs and domain fields
- XMTP and WhatsApp now share one supervised Node bridge port lifecycle while
  retaining their adapter-specific `PortServer` callback/process identities,
  scripts, event tags, and module-scoped warning logs
- Documentation quality checks now use a compact catalog with shared defaults,
  explicit lifecycle/visibility metadata, and Git-index-based coverage that
  ignores untracked local drafts
- Pull-request client quality now exercises Lemon Web startup from clean
  generated artifacts, and release smoke evaluates the MCP library contract
  inside both packaged runtime profiles and their release tarballs
- Local coding-agent patches now preflight every hunk before mutation, reject
  duplicate paths and destructive move overwrites, revalidate each operation,
  exclusively create new targets, and report any committed prefix or partial
  current operation when a later mutation fails. Local writes canonicalize the
  path used for both validation and mutation, then reject symlink redirection
  and special-file targets by default.
- Skill manifests now reject unsafe or oversized prompt metadata, relevance
  searches use cached excerpts/status views outside the Registry server, and
  prompt listings expose bounded source/trust provenance with deterministic
  ordering.
- Turn-specific skill relevance no longer changes the cacheable system prompt;
  missed-skill introspection uses turn-local keys, and local file/search/shell
  plus community skill results are fenced as untrusted data before model calls.
- Skill discovery now invalidates content-addressed caches after file, directory,
  lockfile, environment, or disabled-config changes; malformed typed metadata is
  rejected without crashing. Pre-LLM tool fencing ignores spoofed trust metadata,
  bounds hostile text, avoids double-fencing web output, and attests builtin skill
  content against the bundled release copy before granting instruction trust.
- Product releases can now be cut and published from one manual Release
  workflow dispatch; the workflow derives CalVer, consumes the Unreleased
  notes, commits and tags the release, verifies every artifact, publishes the
  GitHub Release, and only then promotes mutable container channel tags
- Lemon Web shared/server `dist` directories are generated by their build
  commands instead of being tracked as source.

### Fixed

- Redirect acknowledgement now waits until the correction is queued and the
  active model request is signaled, preventing a fast completion from silently
  racing ahead of an accepted redirect.
- Persistent Python kernels now preserve parent/child stdout and stderr ordering
  instead of allowing block-buffered parent output to appear after child-process
  output.
- MCP HTTP transports now supervise the protocol server and Bandit listener as
  one lifecycle and track live node-local instances through supervised members,
  preventing stale or orphaned processes across child failures, concurrent
  starts, and transport shutdowns
- Lemon Web now builds its ignored shared/server entrypoints before clean-checkout
  `npm run dev` and `npm start`; the client quality lane exercises that
  clean-artifact startup contract
- Authenticated TUI control-plane handshakes now send the token in the server's
  `params.auth.token` envelope
- Packaged minimal and full runtimes now assemble the MCP client library, so
  configured MCP tools are discoverable without starting a no-op application
  supervisor
- Named execution nodes now recover the same durable identity after their
  seven-day session expires, survive controller-side renames, revoke older
  sessions on rotation, and provide an explicit repair path for legacy local
  credentials. Non-loopback plaintext controller connections now fail closed
  unless development or a verified encrypted overlay is explicitly selected.
- Named-node challenge exchange and per-identity credential replacement are now
  atomic. Rotation closes stale live sockets, binds result settlement to the
  authorized connection generation, retains a monotonic generation floor
  against delayed handshakes, and withholds ID-based recovery material unless
  the exact stored controller is supplied.
- Closed unauthenticated named-node operator access on the control-plane
  WebSocket: non-loopback operators now fail closed, configured operator tokens
  use constant-time validation, unknown session identities cannot escalate, and
  node pairing reports credential problems without exposing secrets. Tokenless
  loopback operator access is now a default-off explicit compatibility opt-in,
  and browser clients keep operator credentials out of WebSocket URLs.
- The source TUI launcher now gives a fresh launcher-owned daemon and client the
  same high-entropy process-scoped operator token, keeps it out of arguments and
  disk, stops every daemon it starts with the TUI regardless of whether the
  token was generated or preconfigured, and fails closed when attaching to an
  existing runtime without its configured token.
- Named execution nodes now cancel destination work when callers time out,
  disappear, reconnect, or lose their controller socket; bind stored tokens to
  the paired node identity; persist fast results without racing dispatch; and
  resolve relative/default working directories from the joining shell. Node
  sockets now send idle keepalives, pairing resumes safely after approval or a
  lost challenge response, bounded JSON request/result limits prevent
  unbounded worker output, and durable status/events retain only redacted
  result summaries while private source delivery remains intact.
- Router and gateway launch lifecycle now bounds pre-start runtime submission
  and run-launch retries, emits one structured terminal failure before queue
  cleanup, deduplicates tokenized scheduler requests, preserves engine-lock
  exclusivity for live owners, and observes over-age live locks without stealing
  them. Gateway cwd fallback also accepts mixed-key proplists without crashing.
- Async task lifecycle, event retention, and join-followup suppression are now
  serialized and terminal state is first-writer-wins. Run-budget usage and
  child admission are atomic, repeated child completion aggregates once, and
  RunGraph finishes DETS recovery before accepting live calls.
- Corrected context truncation ordering, hard bookends character limits, and
  atomic tool-call/result retention; made pending-compaction retries survive
  submit errors with injection-safe whole-entry history envelopes; and cleared
  stale session follow-up diagnostics/background compaction when turns end or a
  new prompt supersedes the snapshot.
- Heartbeat reconfiguration now updates cron jobs with mutable fields only,
  disables the superseded cron or timer mechanism, preserves nonrepresentable
  intervals with exact timers, records timer terminal/suppression state, and
  skips overlapping timer runs with telemetry. Automation submit-and-wait paths
  now subscribe before submission through one fixed-run-id lifecycle, closing
  synchronous-completion races in cron, goal, heartbeat, and Kanban runs.
- Cron retries now persist due time and lineage across manager restarts, claim
  deterministic attempt IDs, and share one terminal policy path for normal,
  stale, aborted, start-failed, and crashed-worker outcomes. Cron work is
  monitored under the automation task supervisor, with unsupervised execution
  reserved for explicit standalone mode.
- Kanban board stop now hard-cancels owned workers and reclaims their exact
  leases immediately; lease-guarded completion rejects late results, and board
  restart reconciles unexpired leases from the prior dispatcher. Board-scoped
  mutation locks also prevent concurrent dispatchers from leasing the same task
  or racing a stale terminal write against a replacement lease. Goal-loop hard
  stop now claims the fixed run ID before submission, aborts that authoritative
  router run once, and prevents another tick. Router abort tombstones close the
  accepted-before-callback window without delaying stop; graceful stop still
  lets the bounded loop finish and API deadlines enclose configured
  judge/continuation waits.
- Async subagent launches now fail and terminalize their bookkeeping when the
  supervised worker cannot start, completed task/agent followup delivery
  contains router exits, and lane-scheduled jobs no longer process a duplicate
  normal monitor event after every result. Delegated agent runs now participate
  in the run graph used by `agent action=join`, and explicit joins suppress the
  redundant automatic completion followup.
- Child `ask_parent` requests now wake idle parent sessions and release parents
  blocked in task/agent joins so clarification cannot deadlock. Parent-question
  creation and terminal transitions are serialized, resolver authorization is
  exact to both session and agent, and terminal lifecycle events emit once.
- Multi-task `wait_any` joins now suppress automatic followup only for the
  completed winner; failed, aborted, crashed, and restarted joins release
  transient suppression.
  Lane queues discard abandoned callers and contain per-job admission failure,
  while delegated watcher timeouts preserve still-running router authority and
  reconcile late completion from a `tracking_lost` state.

### Removed

- Breaking: top-level engine selection and custom Gateway engine extensions
  were removed. Every conversation now uses the native `CodingAgent.Executor`;
  `LemonGateway.Engine`, `EngineRegistry`, Echo, vendor gateway adapters,
  `LemonCore.EngineCatalog`, and `LemonPlatformTest.EngineCase` no longer
  exist.
- The `engine_id`, `default_engine`, `preferred_engine`, and
  `[gateway.engines.*]` configuration/API selectors are rejected with migration
  guidance. Delegated `task` runs use the native in-process `internal` engine
  only; vendor CLI task runners and `[runtime.cli.*]` configuration were removed.

---

## [2026.08.1]

### Added

- First-run onboarding in packaged `lemon_runtime_min` and
  `lemon_runtime_full` releases, including interactive provider/model setup,
  setup-readiness gating before TUI startup, and installer handoff to the
  setup wizard
- Packaged runtime CLI parity for setup, model, gateway, configuration,
  secrets, channels, and diagnostics commands
- Telegram and Discord gateway setup flows with encrypted credential storage
  and verification
- New Bun/`pi-tui` terminal client with streaming transcripts, tool cards,
  approvals, queue/steer/interrupt controls, multiple sessions, themes, mouse
  support, resolved-model display, and per-run usage
- Persistent supervised Python kernels for `execute_code`, with authenticated
  RPC, bounded requests and execution, cancellation, lifecycle cleanup, and
  redacted telemetry

### Changed

- Installation and onboarding documentation now describes the packaged
  first-run flow and distinguishes installed-runtime commands from source
  wrappers
- Release verification now proves packaged onboarding, source setup
  dispatch, readiness isolation, credential scrubbing, and release artifact
  summaries

### Fixed

- Closed an argument-injection path in packaged doctor dispatch
- Hardened persistent Python kernel ownership, teardown, timeout, spill
  cleanup, and late-frame handling
- Preserved installer `--modify-path` behavior while adding setup handoff
- Corrected provider routing circuit-breaker iteration and hermetic channel
  credential handling
- Made stream-result subscription synchronous so user cancellation cannot be
  miscounted as a provider circuit-breaker failure
- Made the live coding-repair release eval specify the patch tool contract
  explicitly, preventing model-dependent shell-edit detours
- Cleaned cached release assembly directories before packaging so artifacts
  cannot retain stale application or dependency versions
- Corrected secret error type specifications and unreachable CLI config
  branches so the allowlisted `lemon_cli` Dialyzer gate remains clean

---

## [2026.08.0]

### Added

**Distribution — prebuilt install story**
- Prebuilt release tarballs for `linux-x86_64`, `linux-arm64`, and
  `darwin-arm64` (`lemon_runtime_min`/`lemon_runtime_full` everywhere,
  `sim_broadcast_platform` on Linux), each boot-verified on its native
  runner before publication, described by a schema-2 `manifest.json`
- One-line installer (`install.sh`): checksum-verified install into
  `~/.lemon/versions/<version>` with an atomic `current` symlink, plus an
  offline CI verification harness (`scripts/verify_install_script`)
- `bin/lemon` launcher shim shipped inside every release
  (start/daemon/stop/status/version/update/doctor and friends)
- Stage-2 self-update: `lemon update` checks the published manifest,
  stream-downloads with mandatory sha256, stages, flips atomically, and
  supports `--rollback`; the control-plane `update.run` method now rides
  the same code path
- Multi-arch container image `ghcr.io/z80dev/lemon` (amd64 + arm64),
  smoke-tested in CI before tagging; a failed image blocks the release

**Platform (since 2026.05.0)**
- Platform split: 12 packages published to Hex, one native top-level executor,
  delegated CLI runners, and standalone `lemon_browser`/`lemon_skills`
  packages
- Always-on model arenas (werewolf, space station, stock market, survivor,
  poker) with leagues, ratings, and spectator UI
- Provider resilience: failover classifier, unified routing fallback,
  multi-key credential pools with health/cooldown
- Redirect-style interruption end to end, including Telegram/Discord
  `/redirect`
- Learning loop on by default: session search (scoped), routing feedback,
  scheduled skill synthesis
- Tool-search tiered disclosure, programmatic tool calling
  (`execute_code`), cron monitor mode/chaining/drift guard/preflight
- Channel delivery observability, hermetic Telegram test API, and the
  three-tier product verification stack

### Changed
- `lemon_runtime_full` releases now ship digested static assets for both
  web endpoints (previously booted with a static-manifest warning)
- Release artifact naming switched to runner-agnostic platform tags

### Fixed
- Control-plane `update.run` no longer buffers downloads in memory or
  skips checksum verification on unrecognized prefixes
- Sim UI Dockerfile references the post-rename app paths and the shared
  `hex_package.exs`

---

## [2026.05.0]

### Added

**M8 — Documentation and release**
- Condensed root README to 5-minute orientation
- New user-guide docs: `setup`, `skills`, `memory`, `adaptive`
- Architecture overview doc (`docs/architecture/overview.md`)
- CONTRIBUTING.md, SECURITY.md, LICENSE, CHANGELOG.md
- GitHub issue/PR templates
- `product-smoke.yml` CI: packaged runtime boot, control-plane HTTP/WebSocket health, full-profile web health, release support-bundle generation, skill lint, adaptive eval gates
- `release.yml` CI: CalVer tag validation, multi-profile artifact build, manifest.json, GitHub Release publication
- `scripts/bump_version.sh`: coordinated CalVer version bump across mix.exs and client package.json files
- VitePress docs site (`docs/.vitepress/config.js`, `docs/package.json`): optional generated site from repo markdown
- `docs-site.yml` CI: docs build, markdown link checking, and GitHub Pages deployment on push to main
- Lemon 1.0 mainstream readiness ledger, launch website scaffold, install/demo/support pages, comparison page, interface proof pack, fresh-install proof, and release-artifact proof docs
- Linux `x86_64` release support policy for `lemon_runtime_min` and `lemon_runtime_full`, including rollback and downloaded-artifact verification steps
- `scripts/verify_release_artifacts`: verifies release `manifest.json` file names, sizes, and SHA-256 checksums against downloaded or assembled artifacts
- Source and clean Docker install proof on Elixir 1.19.5 / Erlang/OTP 28 with `mix deps.get`, `mix compile`, and redacted doctor bundle generation
- Web operations UI proof for `/ops`, run detail pages, support-bundle download, runtime health, sessions, approvals, cron, skills, channels, memory/log activity, and core config controls
- Telegram source-runtime proof for `/cwd`, progress rendering, prompt round trip, bare `/cancel`, approval-button resolution, and concise invalid-model failures
- TUI source-runtime proof for deterministic echo, rendered tool failure, and real-run cancellation
- Launch-focused safety coverage for web fetch output, inbound email prompts, skill prompt rendering, and extension-style untrusted tool results

**M7 — Adaptive routing and skill synthesis**
- Skill synthesis draft pipeline: candidate selector, draft generator, draft store, orchestration pipeline
- `mix lemon.skill draft` subcommands: `generate`, `list`, `review`, `publish`, `delete`
- Task fingerprinting for routing and synthesis (`LemonCore.TaskFingerprint`)
- Routing feedback store (`LemonCore.RoutingFeedbackStore`)
- Explicit run outcome model (`RunOutcome`: `:success`, `:partial`, `:failure`, `:aborted`)
- Offline evaluation and feedback reporting (`mix lemon.feedback`)

**M6 — Memory and feedback**
- Durable memory store and ingest pipeline (`LemonCore.MemoryStore`)
- Session search API and `search_memory` tool
- Memory management tasks and retention controls
- Memory performance and correctness guardrails

**M5 — Session memory**
- `LemonCore.SessionStore` — JSONL-backed session persistence
- `LemonCore.SessionSearch` — full-text search across past runs
- Memory management and pruning

**M4 — Skill quality**
- Skill audit engine with 5 rules (`LemonSkills.Audit.Engine`)
- Skill install policy with trust tiers
- Official registry namespace and trust policy
- `mix lemon.skill` expanded: `inspect`, `check`, `browse`, `update`

**M3 — Progressive skill loading**
- Unified skill prompt view and activation logic
- Stop inlining full skill bodies in prompts
- Upgrade `read_skill` to structured partial loads
- Prompt/token regression tests

**M2 — Skill installer and registry**
- Manifest v2 parser and validator
- Expanded `LemonSkills.Entry` with lockfile storage
- Source abstraction and source router
- Refactored installer and registry around inspect/fetch/provenance
- Legacy skill migration path

**M1 — Runtime and tooling**
- First-class OTP releases (`lemon_runtime_min`, `lemon_runtime_full`)
- `mix lemon.setup` with interactive subcommands
- `mix lemon.doctor` diagnostics framework with redacted source-dev and release-runtime support bundles
- Staged `mix lemon.update`
- Gateway setup adapters (Telegram, Discord)
- Release smoke tests and packaging docs

**M0 — Foundation**
- Ownership model and CODEOWNERS
- Feature flags and rollout config scaffolding (`LemonCore.Config.Features`)
- Frozen shared schemas and invariants

### Changed

- Root README condensed from 3127 lines to 184 lines (deep content moved to `docs/`)
- CI and docs now target Elixir 1.19.5, Erlang/OTP 28.5, and Node.js 24 LTS.
- Setup docs and config examples now include an OpenAI-compatible endpoint path.
- Public docs now clearly distinguish source install, local artifact proof, and bounded 1.0 support claims.

### Fixed

- Untrusted tool output can no longer bypass the external-content wrapper simply by including both boundary markers.
- Inbound email prompts are wrapped as external untrusted content before router submission.
- Telegram bare `/cancel` now aborts active runs even when the command is not a reply to a progress message.
- Telegram invalid model/config errors now render concise failure text instead of exposing BEAM stack traces.

---

## Release Channels

| Channel | Cadence | Stability |
|---|---|---|
| `stable` | Monthly | Fully tested |
| `preview` | Weekly | Feature-complete, light testing |
| `nightly` | Daily | Automated, may be broken |

See [`docs/release/versioning_and_channels.md`](docs/release/versioning_and_channels.md).
