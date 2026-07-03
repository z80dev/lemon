# Lemon Hermes Parity Expansion Goal

Status: under re-evaluation — 2026-07-02 direction review reweights broad Hermes parity toward sim-as-flagship positioning; workstreams here are paused pending that plan.

Last reviewed: 2026-07-02

## Objective

Advance Lemon from strong harness parity toward broad Hermes product parity on
the next high-value surfaces:

- browser stable parity
- external API and editor integration
- Hermes migration v2
- terminal backend hardening
- plugin/provider ecosystem parity
- LSP editor feedback breadth
- observability everywhere

Each workstream must land as BEAM-native runtime capability, not as an opaque
sidecar bypass. The standard is supervised processes, durable state where the
feature outlives one run, policy gates, telemetry, support-bundle visibility,
operator controls, docs, deterministic tests, and live proof when the surface
depends on external systems.

## Execution Rules

- Ship narrow vertical slices, not broad unproven surfaces.
- Keep every stable parity claim tied to a proof artifact or focused test lane.
- Add `/ops`, control-plane, TUI or channel visibility as part of the feature,
  not after it.
- Treat untrusted browser/plugin/API/editor/terminal output as hostile by
  default and test that boundary.
- Prefer Lemon-native semantics when they are better than Hermes, but preserve
  Hermes-compatible affordances where users will expect them.
- Update this goal, the feature matrix, and the scorecard when a slice changes
  parity status.

## Workstreams

### 1. Browser Stable Parity

Current direction: promote the existing browser preview into a stable,
operator-visible browser automation surface.

Initial slices:

1. Browser session lifecycle status: list active sessions, current page,
   artifact counts, route classification, and last error through control-plane
   and Web `/ops`.
2. Browser artifact lifecycle: retention, cleanup command, support-bundle
   summary, and redacted proof hashes for screenshots/downloads.
3. Browser untrusted-content hardening: deterministic tests for prompt
   injection through page text, evaluated JS output, screenshots, downloads,
   and metadata.
4. Browser plus vision proof: live/local smoke that captures a screenshot,
   sends it through the media vision boundary, and reports redacted proof state.

Acceptance gates:

- focused browser tool tests pass
- live browser smoke passes
- support bundle contains redacted browser diagnostics
- Web `/ops` and control-plane status show the same redacted state

### 2. External API and Editor Integration

Current direction: expose Lemon runs through stable external protocols without
bypassing the run graph, policy engine, memory ingest, approvals, or telemetry.

Initial slices:

1. OpenAI-compatible Chat Completions entrypoint backed by Lemon run submission
   for non-streaming requests.
2. OpenAI-compatible Responses entrypoint with structured status/error
   envelopes and model/provider selection through Lemon routing.
3. ACP/editor adapter proof that starts a Lemon run, streams progress, resolves
   approvals, and records the run in normal memory/history.
4. API redaction and support diagnostics for external clients, including
   client id hashing and request-shape counters.

Acceptance gates:

- request/response schema tests pass
- external API requests create normal Lemon run records
- policy/approval paths are not bypassed
- support bundle includes redacted API/editor diagnostics

### 3. Hermes Migration v2

Current direction: extend the first migration tool from user-data import into a
broader compatibility audit and migration path.

Initial slices:

1. `mix lemon.hermes.audit`: read-only compatibility report for every known
   Hermes source surface, including unsupported items and recommended manual
   actions. Initial implementation exists with text and JSON output.
2. MCP/server migration: translate compatible Hermes MCP server config into
   Lemon capability-source config when safe.
3. Cron migration: import compatible Hermes cron jobs into Lemon automation as
   disabled-by-default drafts with explicit apply controls.
4. Provider routing/fallback/credential-pool migration: map compatible config
   and archive the rest with structured reasons.
5. Full transcript migration investigation: decide whether exact Hermes
   sessions can become Lemon run-history records or must remain memory-only.

Acceptance gates:

- dry-run audit has no side effects
- apply remains preview-first and backup-first
- secrets stay opt-in and redacted
- unsupported Hermes surfaces are explicit, not silently dropped

### 4. Terminal Backend Hardening

Current direction: promote terminal backends from local-first tooling plus
previews into stable, policy-gated execution backends.

Initial slices:

1. Backend status parity: local, Docker, and SSH readiness summaries through
   control-plane, Web `/ops`, TUI, and support bundles.
2. Docker hardening: image/host allow policies, resource limits, cwd mounting
   rules, and redacted logs.
3. SSH hardening: host allowlist, identity/key redaction, session timeout,
   reconnect behavior, and live remote proof.
4. Terminal transcript retention: bounded output summaries, artifact links, and
   failure metadata without leaking secrets or full private output.

Acceptance gates:

- local backend focused tests pass
- Docker and SSH live proofs are explicit before stable claims
- dangerous execution paths require approvals
- support diagnostics contain no raw credentials or command output bodies

### 5. Plugin and Provider Ecosystem Parity

Current direction: make external capability hosting installable, inspectable,
auditable, and degradable.

Initial slices:

1. Plugin host lifecycle: install, enable, disable, update, health, degraded
   startup, namespace conflict, and uninstall flow.
2. Provider plugin contract: extension-provided model/memory/tool providers
   with registration, unregister cleanup, and status visibility.
3. Marketplace/index audit: signed or reviewed registry metadata, lockfile or
   provenance capture, and update drift reporting.
4. Capability policy wrappers: MCP/WASM/plugin tools all report capabilities
   consistently and inherit approval defaults.

Acceptance gates:

- plugin host lifecycle tests pass
- provider registration/unregistration is supervised
- support bundle and Web `/ops` show redacted plugin/provider state
- untrusted plugin outputs have prompt-injection tests

### 6. LSP Editor Feedback Breadth

Current direction: move from diagnostics preview to editor-grade feedback loops.

Initial slices:

1. Editor session bridge: open/change/close document state connected to editor
   clients instead of only tool-triggered checks.
2. Baseline/delta promotion: stable post-edit diagnostic summaries for common
   language workflows.
3. Code action and quick-fix investigation: determine which LSP actions can be
   surfaced safely through Lemon approvals.
4. Full-fleet proof upkeep: keep Elixir, TypeScript, Python, Rust, Go, and C/C++
   fixture lanes current.

Acceptance gates:

- LSP JSON-RPC/session tests pass
- real-repo full-fleet smoke passes
- editor-facing diagnostics do not expose raw private file contents in reports
- post-edit diagnostics are visible in run detail and `/ops`

### 7. Observability Everywhere

Current direction: every parity surface should be inspectable, supportable, and
recoverable through the same Lemon operator plane.

Initial slices:

1. Status method inventory: enumerate every parity surface and whether it has a
   control-plane status method, Web `/ops` panel, support-bundle entry, proof
   artifact, and TUI/channel command.
2. Unified proof gate model: normalize completed/failed/skipped/missing proof
   reporting across browser, media, terminal, LSP, provider, channel, plugin,
   and migration surfaces.
3. Redaction contracts: shared tests for ids, paths, prompts, provider
   responses, command output, browser page text, plugin output, and diagnostic
   payloads.
4. Operator recovery controls: stop/restart/cleanup/retry controls for browser
   sessions, terminal backends, plugin hosts, LSP sessions, media jobs, and API
   clients.

Acceptance gates:

- support bundle has a redacted diagnostic entry for each stable surface
- Web `/ops` can explain each unresolved launch gate
- control-plane status methods are schema-tested
- proof artifacts are hash-addressable without exposing raw contents

## First Implementation Order

1. Hermes migration v2 audit mode
2. Browser stable status and artifact lifecycle
3. Observability inventory and proof-gate normalization
4. Terminal backend status parity
5. External API Chat Completions entrypoint
6. LSP editor bridge slice
7. Plugin/provider lifecycle hardening

This order front-loads work that improves operator clarity and makes later
parity claims easier to prove.
