# Changelog

All notable changes to `lemon_control_plane` are documented here.

## [Unreleased]

### Removed

- **Breaking:** the OpenAI-compatible `/v1` HTTP API, the single-shot
  `POST /acp` endpoint, their dedicated API-token principals
  (`Authorize.authenticate_api/3`, `LEMON_ACP_API_TOKEN` and the OpenAI-compat
  token and image-fetch variables), the `LEMON_CONTROL_PLANE_REMOTE_HTTP`
  opt-in and the ACP API-workspace confinement they required. The loopback
  `/acp/ws` transport behind `lemon acp` is unchanged; remote peers reach only
  `/ws` and `/healthz` (#711).

### Fixed

- `agent.wait` reports `UNAVAILABLE` when the run store cannot be read instead
  of waiting out the timeout, never puts a raw exception message in error
  details, and validates `runId`/`timeoutMs`. `cron.runs` never renders a
  non-text output term onto the wire (#620).
- `LemonControlPlane.UsageTokens` reports `contextTokens` from the run's latest
  provider call (`LemonCore.Events.Usage.context_tokens/1`) instead of the run's
  cumulative cache-inclusive input, and reads only canonical usage field names.
  `agent.wait` projects the typed run usage (#669).
- A method with any scope beyond `:read` that raises, throws or whose async task
  dies now answers `INTERNAL_ERROR` with `details.retrySafe: false`, so clients
  never retry a mutation that may already have applied (#616).

### Added

- Admin-only `browser.stop` stops the local browser driver and the Chrome it
  launched; attached browsers keep running (#660).
- `system.stop` drains active runs and carries queued work across the restart
  (`LemonCore.Drain`) before the VM stops.
- Admin-only `system.reload_code` soft-loads changed code in launcher-managed
  interactive source runtimes, optionally refreshes idle session tools, and
  retries modules still in use once. Bounded module lists retain exact counts;
  failure reasons never expose paths or raw runtime terms.
- `agent` accepts a validated per-invocation `project_memory_capture` boolean;
  one-shot print clients disable auxiliary extraction without changing recall.
- Agent submissions accept validated `session_mode` and `persona` options,
  allowing one-shot coding clients to omit assistant-home bootstrap while
  assistant/chat clients retain their existing context.
- Admin-only `profile.followup.admission.get` returns configuration presence, URL
  and the lowercase SHA-256 token digest for reconciliation, never credentials
  or their secret names. Admission setters and cron mutations report distinct
  safe callback error codes; only origin rejection includes a canonical origin.
- Admin-only controller and named-node Codex device login start/poll/cancel plus
  internal challenge/completion/settlement RPCs, with complete binding schemas and
  fixed identities. Completion carries the exact destination-generated nonce,
  never a cross-machine wall-clock deadline. The target enforces its own
  five-second monotonic nonce lifetime; new completions inspect and pin the
  current node connection and generation. Non-writing fixed-ID settlement uses
  the current connection even after token expiry, session replacement or restart.
  Revocation/re-pairing never waits for unresolved provider work. Only exact
  destination `provider_binding_rejected` errors attest that request's login
  binding was rejected without writing; generic denial and later pre-dispatch
  rejection do not resolve an earlier uncertain completion. Public results remain
  allowlisted; challenges, OAuth tokens and upstream failures never reach clients.

- Admin-scoped target-bound provider capability/status listing, write-only API-key
  add/replace, local disconnect and explicit default selection for the controller
  and authenticated execution nodes. Credentials stay in the selected target's
  encrypted secret store and provider configuration through CLI onboarding
  persistence; local disconnect is not provider-side revocation.

- Admin-scoped controller and named-node provider readiness checks
  (`providers.management.check`, `node.providers.management.check`) use bounded
  non-generating discovery. Explicit Codex CLI import (`providers.management.import`,
  `node.providers.management.import`) stays destination-local and maps missing or
  unusable logins to conflicts; listings optionally include readiness.

### Changed

- **Breaking:** the `agent` method takes `sessionKey`, `agentId` and `queueMode`
  (the advertised schema spelling) and an optional fixed `runId`; the old
  `session_key`, `agent_id` and `queue_mode` are rejected instead of being
  silently ignored. It submits through the `chat.send` receipt path and returns
  `runId`, `sessionKey`, `state`, `effectiveMode`, `targetRunId` and
  `retrySafe: false`. An `agentId` naming a managed profile runs as that
  profile's chat in its workspace and rejects a caller `cwd`. Unknown queue
  modes are rejected (#620).
- `node.process.run`, `.get` and `.cancel` receipts accept the terminal state
  `failed` (null exit and outputs): the destination proved the program never
  started. Terminal receipts now retire on the destination 24 hours after they
  finish; only unresolved receipts count toward its 1,000 limit (#679).

- **Breaking security change:** HTTP/WebSocket listeners default to loopback.
  LAN deployments must explicitly configure `LEMON_CONTROL_PLANE_BIND_IP` and
  authentication. The separate node gateway defaults to `127.0.0.1:4044`;
  off-loopback OpenAI/ACP HTTP access requires explicit opt-in and dedicated tokens.
- **Breaking:** `sessions.reset` delegates to `LemonCore.SessionLifecycle.reset/2`
  and is preview-first. Without `confirmToken` (or with `dryRun: true`) it
  mutates nothing and returns the state digest and a single-use `confirmToken`;
  `dryRun: false` with that token resets under the session lifecycle fence.
  Failures map to `unavailable`/`internal_error` with `retrySafe: false` and no
  raw exception text (#615).
- ACP session metadata is stored on the canonical `SessionMetadataStore` record
  instead of a separate ACP table and is removed with the session; ACP sessions
  created before this release are not carried over (#652).

### Fixed

- A method with any scope beyond `:read` that raises, throws or whose async task
  dies now answers `INTERNAL_ERROR` with `details.retrySafe: false`, so clients
  never retry a mutation that may already have applied (#616).

- `sessions.snapshot` compares its two owner collections without
  `consistency.eventCursor`: a live event between them returns the newer
  collection and its cursor (read in one owner call) instead of
  `snapshot_raced` (#628).
- `sessions.snapshot` approvals carry `command`, `path`, `plan`, a bounded
  `argumentsPreview` and per-item `truncated`/`planTruncated` flags, so a
  recovered approval never renders as hashes only and a clipped plan is never
  presented as complete; the approvals budget is 16,384 bytes (#654).
- Read methods fail closed on store and runtime failures (`UNAVAILABLE`, never
  empty/idle/not-found); `cron.status` reports `null` counters, an
  `unavailable` section list and `enabled: null` for an unreadable job list; a
  node whose registry read fails gets a retryable `UNAVAILABLE` at `connect`.
  `ConfigStore` and `LogRing` reads return tagged results (#619).
- `memory.transfer` releases a local source's frozen memory snapshot as soon
  as the destination receipt is recorded instead of keeping it indefinitely (#623).
- `memory.transfer` releases the source's frozen memory snapshot as soon as the
  destination receipt is recorded instead of keeping it indefinitely: directly
  for a local source, and through `memory.transfer.release` (best effort, five
  seconds) for a remote source worker that advertises it (#623).
- Timeouts, closed openers and unclassified failures of passive node inspections
  (`node.capabilities.get`, `node.runtime.features`, `node.host.info`) are
  retry-safe unavailable reads, not uncertain mutations.
- Register controller and named-node provider check/import handlers in the RPC
  method registry so clients can discover and invoke model-readiness capabilities.
- ACP never writes a stored resume token back into `ChatState`, so a reset or
  deleted session stays empty after a later ACP touch. Session store failures
  fail closed, and a store write failure after prompt submission returns the
  run ID with `retrySafe: false` instead of raising (#652).

- Honor the configured HTTP/WebSocket listener IP, including isolated benchmark
  runtimes and explicitly exposed deployments.
- Preserve explicitly reported positive usage costs independently of unavailable
  token counters, including historical cost-only records and completed agent
  events. Explicit unknown prices still win, and partial cache counters remain
  null rather than becoming zero or complete run totals.

- Generic node invocation cannot bypass provider-management administration scopes.
  Provider-management exceptions and node transport diagnostics omit raw request
  values; uncertain mutation failures explicitly prohibit automatic retry.
