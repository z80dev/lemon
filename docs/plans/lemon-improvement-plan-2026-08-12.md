# Lemon Improvement Plan — from the 2026-08-11 Hermes Gap Audit

Status: adopted plan (source audit: `lemon-hermes-gap-audit-2026-08-11.md`)

This plan deliberately does **not** try to close every gap. It picks the
improvements with the highest runtime leverage per unit of surface area,
sequenced so each phase leaves the repo shippable. Phases 1–3 are committed
work; Phase 4 is queued next; Phase 5 is a decision list, not a work list.

Grounding: every item below was verified against the code on 2026-08-12
(two deep code surveys: provider-resilience plumbing; interruption +
memory-flag paths). File/line references are from that snapshot.

---

## Phase 1 — Provider resilience (the P0, start here)

**Status: DONE (2026-08-12)** — landed on main as commits `2efc4ae7..807517c9`
(classifier-driven fallback, single routing plan + breaker demotion,
unconditional wrapping, credential pools with health/rotation/pinning).
Open follow-up: run the live pool smoke (`credential_pool_rotation` scenario)
with real credentials.

Goal: real live fallback chains + credential pools, unified with the
existing diagnostics, without wrecking prompt caches.

### What exists today (why this is cheap leverage)

- `LemonAgent.ModelRuntime.ProviderRouting` is **describe-only** ("preview"):
  full ordering/readiness logic, zero runtime callers.
- `CodingAgent.Session.ProviderFallback` is the only live executor. Its
  commit semantics are already right (pre-commit event buffering, latch on
  first useful token). But its classifier is a stub —
  `retryable_error?/1` returns `true` for everything
  (`provider_fallback.ex:180`), so a 400 or context-overflow burns the whole
  chain — and it only wraps **default-model** sessions
  (`session/lifecycle.ex:145-153`).
- `LemonAi.Error` (1,031 lines) already classifies errors into
  `:rate_limit | :auth | :client | :context_length | :server | :transient`
  with retry-after parsing. **Nothing in the fallback path uses it.** Three
  divergent "retryable" definitions exist (`Error`, `RetryHelper`,
  `CallDispatcher.circuit_breaker_failure?/1`).
- "Credential pools" in config are lists of **provider names**;
  `Credentials.build_get_api_key/1` returns one key per provider. No
  multi-key support anywhere.
- `ModelResolver.routing_fallback_providers/2` **reimplements** the ordering
  ProviderRouting computes; only one of them consults the pool rotator, only
  the other checks provider statuses — preview and live behavior can
  disagree today.
- Circuit breaker / rate limiter state is never consulted when building the
  candidate chain.
- `ProviderPoolRotator` has no session dimension in its key
  (`{:provider_pool, profile, pool, model_id}`), so round-robin rotation
  churns provider prompt caches across sessions.

### 1.1 Failover classifier (do first — smallest, unblocks everything)

- Add `LemonAi.Error.failover_action/1` →
  `:retry_same | :next_credential | :next_provider | :compact | :fail`,
  built on the existing `classify_error/3`:
  - `:auth` → `:next_credential`, then `:next_provider`; never retry same key
  - `:rate_limit` → `:next_credential` (honor
    `suggested_retry_delay_from_error/1`), then `:next_provider`
  - `:transient` / `:server` → `:next_provider`
  - `:context_length` → `:compact` — **never** failover
    (`CompactingClient` already owns this)
  - `:client` → `:fail` (identical failure everywhere)
- Replace `ProviderFallback.retryable_error?/1` with it.
- Collapse `RetryHelper`'s status list and
  `CallDispatcher.circuit_breaker_failure?/1` onto the same source of truth.
- Prereq check: verify provider stream errors reaching
  `relay_attempt/2` carry status/body enough to classify; thread a parsed
  error through if not.
- Also fixes: `CallDispatcher.record_stream_terminal_result/2` treats all
  stream errors as breaker failures — a bad credential currently trips a
  whole provider's breaker.

### 1.2 One routing plan, two consumers

- Promote `ProviderRouting` from preview to plan-producer:
  `plan/3` returning ordered structured candidates
  (`%{provider, role, credential_ref, pool, strategy}`).
- `preview/3` renders that plan; `ModelResolver.runtime_fallback_models/2`
  consumes it; delete `routing_fallback_providers/2`
  (`model_resolver.ex:359-389`).
- Candidate selection consults `CircuitBreaker.open?/1` — demote (not drop)
  open-breaker providers.
- Outcome: `mix lemon.providers` / control-plane `providers_status` become
  an honest description of live behavior.

### 1.3 Credential pools (actual credentials)

- Extend `normalize_credential_pools/1` (`lemon_core/config/agent.ex:298`)
  so a pool entry can carry **multiple credentials per provider** (list of
  `api_key_secret` / env names), not just provider names. Relax the
  empty-`providers` drop rule for credential-only pools.
- Generalize `Credentials.build_get_api_key/1` into a pool-aware resolver
  returning an ordered list of credential handles with health state; keep
  the arity-1 closure as a `List.first/1` shim so existing callers
  (`Agent.get_api_key`, `ProviderFallback.ensure_api_key/4`) keep working.
- Selection point: `Loop.Streaming.stream_assistant_response/5` L48-60 —
  it already re-resolves the key every turn. Per-attempt advance point:
  `ProviderFallback.ensure_api_key/4`.
- Health/cooldown table keyed `{provider, credential_ref}` (mirror
  `RateLimitHealer` cooldown/backoff + `CircuitBreakerRegistry` via-tuple
  pattern). `run_candidates/8` records classified failures on each hop;
  the resolver skips credentials in cooldown.

### 1.4 Cache-aware stickiness (do not skip)

- Add `session_id` to the `ProviderPoolRotator` key so a session pins one
  credential; make a taken failover **sticky for the rest of the session**.
- Rationale: provider prompt caches are per-key and non-portable
  (Anthropic ephemeral blocks, OpenAI `prompt_cache_key`); per-request
  rotation silently destroys hit rates.

### 1.5 Coverage

- Move `ProviderFallback.maybe_wrap/4` out of the
  `opts[:model] == nil` conditional — explicit-model sessions get fallback
  too (same model id, different provider).
- Wrap the gateway path (`gateway_engine/session_runner.ex:162`).
  CLI-runner / evals / sim `stream_fn` sites stay unwrapped (deliberate).

### 1.6 Acceptance

- Extend `scripts/live_provider_fallback_smoke.exs`:
  (a) credential-pool case — two bad keys then a good one, same provider;
  (b) negative case — a 400 client error must **not** walk the chain.
- `ProviderStatus.live_proofs/1` already surfaces results into
  `mix lemon.providers` + doctor; keep `.lemon/proofs/` as the gate.

Suggested order: 1.1 → 1.2 → 1.5 → 1.4 → 1.3 → 1.6 (classifier and plan
unification are independent of pools and land value alone; pools are the
biggest chunk and ride on both).

---

## Phase 2 — Redirect interruption

**Status: DONE (2026-08-12)** — landed on main as commit `d1188a00` (separate
redirect ETS bit, `stop_reason: :redirected`, loop re-entry with the queued
correction, degrade-to-steer, gateway capability). Open follow-up: wire a
channel-facing redirect verb (Telegram/Discord) onto the gateway capability.

Goal: Hermes's third interruption mode — cancel only the in-flight model
request, keep completed tool results, append the correction, retry —
so a mid-stream course-correction doesn't wait for the turn to finish or
kill the run.

What exists: abort is one global bit per run in ETS
(`LemonAgent.AbortSignal`, polled by loop + ~20 tools); steering only lands
between turns / after a tool batch; the in-flight cancel primitive already
exists in isolation (`LemonAi.EventStream.cancel/2`, used today only from
the abort path).

Work items (natural seam confirmed in code):

1. **Signal**: distinct redirect state — don't overload the abort bit
   (`aborted?/1` must keep meaning "stop" for the 20+ tool call sites).
   Second ETS value or sibling module on the same table-owner pattern.
2. **Streaming**: check redirect in the `reduce_while` guard
   (`loop/streaming.ex:112-133`), cancel with reason `:redirected`, map to
   a new `stop_reason: :redirected` in `finalize_canceled_message/6`.
3. **Loop**: new `:redirected` clause in `do_inner_loop/11`
   (`loop.ex:526`) that *continues* instead of halting: drop the partial
   assistant message (must not leave unanswered `ToolCall` blocks —
   `TranscriptValidator` runs every turn), clear the redirect bit, drain
   steering as pending messages, recurse. `process_pending_messages/4`
   appends the correction before the retry call.
4. **Plumbing**: `Agent.redirect/2` (enqueue into steering queue + set
   bit; keep `state.abort_ref` a plain ref so `was_aborted` bookkeeping
   stays correct), `Session.redirect/2`, `SessionRunner` sibling of
   `{:steer, ...}`, gateway `supports_redirect?()` capability next to
   `supports_steer?()`.
5. **Degrade rule** (Hermes parity): redirect during tool execution
   degrades to steer — tools are not cancelled.

---

## Phase 3 — Memory on by default (with guardrails)

**Status: DONE (2026-08-12)** — landed on main as commits `ad251ee6` and
`5b0b528e` (`session_search` default-on, memory doctor check, anti-capture
selection policy, ingest config caching). Post-review hardening: the
`session_search` tool now defaults discovery/scroll to the calling agent's
own sessions with an explicit `:all` opt-in, and redacts secret-looking
run-history content.

Goal: the learning loop stops being inert on fresh installs.

What exists: `LemonMemory.Ingest` is already wired into
`finalize_run_hooks` unconditionally; the flag (`session_search`, default
`:off` in `LemonCore.Config.Features`) is checked inside the worker. The
model is **already prompted** with `session_search`/`search_memory` tools —
they just return empty today. Redaction is drop-not-redact via 5 regexes
(`LemonMemory.Safety`).

Work items, in order:

1. **Anti-capture policy first** (before the flip, so bad memories never
   accumulate): in `LemonSkills.Synthesis.CandidateSelector.qualified?/1`,
   (a) drop `:partial` from `good_outcome?/1` — `RunOutcome.infer/1` labels
   clean give-ups `:partial`, exactly the "this tool doesn't work" shape
   Hermes warns hardens into refusals; (b) add a content predicate
   rejecting negative tool claims / unresolved-failure phrasing as a sixth
   conjunct.
2. **Ingest hot-path fix**: `LemonCore.Config.Modular.load()` runs per
   finalized run inside `Ingest` (`ingest.ex:101`); cache it (config
   already has hot-reload machinery) before writes become real.
3. **Flip `session_search` → `default-on`.** Keep drop-not-redact. Retention
   stays 30 days / 500 per scope.
4. **Risk mitigations shipped with the flip**:
   - a doctor check that reports store size + last-ingest so the feature is
     observable;
   - documented kill switch (`LEMON_FEATURE_SESSION_SEARCH=off`) in the
     memory docs;
   - a quick behavioral pass on suddenly-populated recall (the prompt
     already advertises the tools — verify the model uses results sanely).
5. **Not in this phase**: `routing_feedback` and `skill_synthesis_drafts`
   stay `opt-in`. Rationale: routing feedback rides on the same documents
   and can graduate once ingest is proven; synthesis is only reachable from
   `mix lemon.skill` today, so its rollout gate (`LemonRouter.RolloutGate`)
   has no data — wiring synthesis into automation is a Phase 4 candidate,
   and graduation follows the documented thresholds.
   **Superseded (2026-08-14):** both flags were promoted to `default-on` by
   decision, and the `LemonRouter.RolloutGate` machinery (module, store-based
   evaluators, per-pass gate verdicts, doctor READY/accumulating language)
   was removed entirely. `SynthesisMetrics` rows survive as pure
   observability for the `automation.skill_synthesis` doctor check; the
   `opt-in` flag state remains parseable for legacy configs.

---

## Phase 4 — Queued next (P1, pick up after 1–3)

In rough priority order; each is independently landable:

1. **Cron quality quartet** (small, high perceived quality, all inside
   `lemon_automation`): monitor mode (hash-suppressed change detection),
   job chaining (`context_from`), model drift guard (fail closed when the
   global default model changed under an unpinned job), pre-dispatch
   preflight (no LLM call on misconfig).
2. **Tool-search progressive disclosure** for MCP-heavy sessions: swap
   registered tool schemas for bridge tools + tiered catalog past a context
   budget. (Keep tool ordering deterministic — prompt-cache guard already
   documented in `tool_registry.ex`.)
3. **Synthesis-into-automation**: schedule the synthesis pipeline (it's
   mix-task-only today) so the rollout gate accumulates real data; then
   revisit the Phase 3 deferred flags.
4. **Programmatic tool calling**: script-over-RPC with results staying out
   of context. Evaluate a BEAM-port or WASM-sidecar transport (we already
   have `coding_agent/wasm/`) rather than copying Hermes's file-RPC.
5. **Hygiene sweep** (can ride along with any phase):
   - delete or wire the 11 orphaned tool modules in
     `coding_agent/tools/` (`exec`, `await`, `ask_parent`, `restart`,
     `multiedit`, `glob`, `todoread`, `todowrite`, `webdownload`, `fuzzy`,
     `process`);
   - mark the May 2026 parity matrix historical; this audit + this plan
     are the live ledger;
   - fix scorecard drift (`/ops` slices that moved to `clients/lemon-web`).

---

## Phase 5 — Deliberate decisions, not work (yet)

Decide and record in `docs/compare.md`; no implementation until chosen:

- **Channels**: if/when we add one, Slack first (then Signal or Matrix),
  plus a unified pairing/allowlist subsystem in `lemon_channels` — breadth
  for its own sake is a non-goal.
- **Distribution**: one-line installer + binary release is the single
  biggest adoption gap; serverless terminal backend (Modal/Daytona-class)
  is the "cheap when idle" story. Big lift, needs a product decision.
- **Voice**: smallest credible step is closing the Telegram loop (inbound
  transcription exists; add TTS reply). Everything past that is deferred.
- **Declared non-goals** (write them down): desktop app, pets/skins,
  CN-market platforms, wake word, subscription proxy.

---

## Out of scope for this plan

- The 12 architecture-policy violations from the vendor-engine move
  (bless-vs-invert) — separate standing decision, deliberately unfixed.
- Publishing `lemon_cli_runners` to Hex — user-gated. **Moot since 2026-08-21:**
  the package was removed (D16 in `docs/platform-split.md`); subagents are
  native-only.
- Re-pinning the Hermes baseline — superseded by adopting the 2026-08-11
  audit as the live ledger (Phase 4.5).
