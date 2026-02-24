# Landing: Debt Phase 9 — Gateway Runtime Reliability Decomposition

## Plan ID
PLN-20260222-debt-phase-09-gateway-reliability-decomposition

## Status
Landed

## Landing Checklist

- [x] M1: Baseline investigation complete
- [x] M2: `FanoutSupervisor` added to `LemonControlPlane.Application` supervision tree; EventBridge no longer starts Task.Supervisor ad hoc
- [x] M3: `prepare_attachments/1` + `schedule_attachment_writes/1` split; webhook returns 202 immediately; async I/O via `LemonGateway.TaskSupervisor`
- [x] M4: `LemonGateway.DependencyManager` extracted; `Engines.Lemon`, `Transports.Discord`, `Tools.Cron`, `Run` migrated from scattered `Application.ensure_all_started` calls
- [x] M5: `mix compile --no-optional-deps` clean; `mix test` gateway + control_plane pass; `mix format --check-formatted` clean
- [x] Gap fix applied: `email/inbound_security_test.exs` updated to use `assert_eventually` for async attachment write (19/19 event_bridge tests + 8/8 email security tests pass post-fix)
- [x] Review artifact created and approved (`RVW-PLN-20260222-debt-phase-09-gateway-reliability-decomposition.md`)
- [x] Workspace hygiene verified (`_build`/`deps` not tracked)
- [x] INDEX.md updated: plan moved from Active to Recently Landed
- [x] JANITOR.md updated with session summary

## Landing Notes

- Core implementation commit: `2702f964` (`debt(phase-09): gateway runtime reliability decomposition`) — already an ancestor of `main` at landing time.
- Gap fix commit (test sync): included in workspace change `zrxozxwz` in `lemon-phase9`.
- Final `main` after landing: includes both the original phase-09 commit and the test fix stacked on top.

## Conflict Watch List

- `apps/lemon_gateway/test/email/inbound_security_test.exs`: only file modified in this workspace; no conflicts expected with other in-flight plans.
- `planning/INDEX.md`: updated to move plan to Recently Landed — reconcile if another plan lands concurrently.
- `JANITOR.md`: append-only entry — no conflicts.
