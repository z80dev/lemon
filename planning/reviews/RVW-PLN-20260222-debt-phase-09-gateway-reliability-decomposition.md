# Review: Debt Phase 9 — Gateway Runtime Reliability Decomposition

## Plan ID
PLN-20260222-debt-phase-09-gateway-reliability-decomposition

## Review Date
2026-02-24

## Reviewer
codex

## Status
Approved — no blocking defects; one gap found and fixed.

## Scope Reviewed

All five milestones from the plan:

- M1: Baseline investigation
- M2: EventBridge fanout supervisor under OTP supervision tree
- M3: Email inbound async attachment pipeline
- M4: Engine dependency abstraction via `LemonGateway.DependencyManager`
- M5: Tests, formatting, documentation

## Verification Snapshot

### M2 — EventBridge FanoutSupervisor

- `LemonControlPlane.Application` supervision tree: `{Task.Supervisor, name: LemonControlPlane.EventBridge.FanoutSupervisor}` at line 18 — **confirmed**.
- `LemonControlPlane.EventBridge`: no `Task.Supervisor.start_link` ad-hoc call — **confirmed**.
- `mix test apps/lemon_control_plane/test/lemon_control_plane/event_bridge_test.exs apps/lemon_control_plane/test/lemon_control_plane/event_bridge_tick_test.exs` → 19 tests, 0 failures.

### M3 — Async Attachment Pipeline

- `LemonGateway.Transports.Email.Inbound`: `prepare_attachments/1` (sync, deterministic target path) and `schedule_attachment_writes/1` (async via `LemonGateway.TaskSupervisor` or bare `Task.start`) — **confirmed** at lines 394–539.
- Webhook handler returns 202 before any file I/O — **confirmed** (line 78).

**Gap found:** `apps/lemon_gateway/test/email/inbound_security_test.exs` test `"copies Plug.Upload attachments to restricted temp files"` checked `File.ls(@attachments_dir)` synchronously immediately after `Inbound.ingest/2`, but the write now happens in a background task. This caused a `{:error, :enoent}` failure.

**Fix applied:** Added `import LemonGateway.AsyncHelpers` and wrapped the `File.ls` assertion in `assert_eventually/2` with a 2-second timeout. All 8 email security tests now pass.

### M4 — DependencyManager

- `LemonGateway.DependencyManager` module exists with: `ensure_app/1`, `available?/1`, `exports?/3`, `broadcast/2`, `build_event/3`, `emit_telemetry/2` — **confirmed**.
- `LemonGateway.Engines.Lemon`: uses `DependencyManager.ensure_app(:coding_agent)` (line 61) — **confirmed**.
- `LemonGateway.Tools.Cron`: uses `DependencyManager.ensure_app(:lemon_automation)` (line 375), `DependencyManager.exports?/3` (line 395) — **confirmed**.
- `LemonGateway.Transports.Discord`: no bare `Application.ensure_all_started` call — **confirmed**.
- Remaining `Application.ensure_all_started` in gateway lib is only inside `DependencyManager` itself (correct) and the `mix/tasks/lemon.voice.secrets.ex` Mix task (acceptable — CLI context) — **confirmed**.

### M5 — Format / Compile

- `mix compile --no-optional-deps` clean on modified files — **confirmed** (prior JANITOR entry at 2026-02-22T00:50).
- `mix format --check-formatted` clean — **confirmed** (prior JANITOR entry).

## Test Results

| Suite | Tests | Failures |
|-------|-------|----------|
| `apps/lemon_control_plane` event_bridge + tick | 19 | 0 |
| `apps/lemon_gateway` email/ + lemon_gateway/ + engines/ | 233 | 0* |

*One flaky introspection test (`IntrospectionTest:151`) fails only under full-suite parallel load due to a pre-existing timing sensitivity unrelated to phase 09; passes in isolation.

## Findings

1. **[Fixed]** `email/inbound_security_test.exs` was not updated when the attachment pipeline was made async. Added `assert_eventually` to synchronize the file existence check.
2. No other blocking defects found.

## Recommendation

Approve for landing. The gap fix (test sync) is merged into this workspace change.
