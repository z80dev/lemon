# PLN-20260222: Debt Phase 9 — Gateway Runtime Reliability Decomposition

## Status: ready_to_land
**Owner:** janitor
**Reviewer:** janitor

## Goal
Harden gateway runtime reliability by placing the EventBridge fanout supervisor under proper OTP supervision, moving email attachment parsing off the request handler critical path, and replacing scattered engine dependency bootstrapping with an explicit dependency manager.

## Milestones

- [x] **M1** — Baseline investigation (identify patterns, document current state)
- [x] **M2** — EventBridge fanout supervisor under application supervision tree with restart semantics
- [x] **M3** — Email inbound async attachment pipeline (off critical path)
- [x] **M4** — Engine dependency abstraction (explicit dependency manager boundary)
- [x] **M5** — Tests pass, format clean, documentation updated

## Workstreams

### 1. EventBridge Supervision Hardening (M2)
- `LemonControlPlane.EventBridge` lazily starts `FanoutSupervisor` via `ensure_fanout_supervisor_started/0`
- The Task.Supervisor is started ad hoc outside the supervision tree, so crashes are unrecoverable
- **Fix:** Move `FanoutSupervisor` into `LemonControlPlane.Application` supervision tree as a named child
- Remove ad hoc `Task.Supervisor.start_link/1` from EventBridge; rely on supervised process

### 2. Email Inbound Async Attachment Pipeline (M3)
- `Inbound.ingest/2` calls `persist_attachments/1` synchronously during the HTTP request handler
- Large attachments (up to 10MB) block the webhook response, risking HTTP timeouts
- **Fix:** Move attachment persistence to an async Task, return 202 immediately with attachment metadata placeholders
- Attachment paths are resolved asynchronously and available by the time the engine run starts

### 3. Engine Dependency Abstraction (M4)
- `Engines.Lemon.start_run/3` calls `Application.ensure_all_started(:coding_agent)` inline
- `Transports.Discord` calls `Application.ensure_all_started(:nostrum)` inline
- `Tools.Cron` calls `Application.ensure_all_started(:lemon_automation)` inline
- `Run.emit_to_bus/4` and telemetry helpers use `Code.ensure_loaded?` guards scattered throughout
- **Fix:** Extract `LemonGateway.DependencyManager` module that centralizes dependency checks and app startup
- Engines and tools call `DependencyManager.ensure_app/1` instead of direct Application calls
- Bus/telemetry availability checks go through `DependencyManager.available?/1`

## Exit Criteria
- [x] EventBridge fanout supervisor is a supervised child with restart semantics
- [x] Email inbound request latency remains stable under large attachment scenarios
- [x] Engine startup path no longer contains scattered direct dependency bootstrapping logic

## Progress Log

| Timestamp | Milestone | Notes |
|-----------|-----------|-------|
| 2026-02-22T00:00 | M1 start | Analyzed EventBridge, Email.Inbound, engine startup patterns |
| 2026-02-22T00:10 | M1 done | Identified lazy FanoutSupervisor, sync attachment persist, scattered ensure_all_started |
| 2026-02-22T00:20 | M2 done | FanoutSupervisor added to LemonControlPlane.Application supervision tree; EventBridge init no longer starts Task.Supervisor ad hoc; fallback inline dispatch on supervisor unavailability |
| 2026-02-22T00:30 | M3 done | Email Inbound attachment persistence split into prepare_attachments (sync metadata) + schedule_attachment_writes (async Task via LemonGateway.TaskSupervisor); webhook returns 202 immediately |
| 2026-02-22T00:40 | M4 done | LemonGateway.DependencyManager extracted with ensure_app/1, available?/1, exports?/3, broadcast/2, build_event/3, emit_telemetry/2; Engines.Lemon, Transports.Discord, Tools.Cron, Run all migrated |
| 2026-02-22T00:50 | M5 done | mix compile --no-optional-deps clean; mix test apps/lemon_gateway apps/lemon_control_plane pass (exit 0); mix format --check-formatted clean on all modified files |
| 2026-02-25T14:20 | Close-out docs | Reconciled plan metadata with planning workflow (`ready_to_land`), added review + merge artifacts, and updated planning index/JANITOR continuity notes. |
