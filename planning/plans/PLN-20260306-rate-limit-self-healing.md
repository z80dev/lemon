---
id: PLN-20260306-rate-limit-self-healing
title: Rate-Limit Session Self-Healing
owner: janitor
reviewer: (pending)
status: planned
workspace: feature/pln-20260306-rate-limit-self-healing
change_id: pending
created: 2026-03-06
updated: 2026-03-06
---

## Goal

Implement session-level self-healing for rate-limited sessions that become permanently wedged even after global rate limits reset. This complements the auto-resume feature (PLN-20260303) by adding in-session recovery mechanisms when a single session remains stuck while new sessions can proceed normally.

## Background

Community reports (Claude Code #26699) document a painful failure mode where a long-running session gets permanently stuck in a rate-limited state. Even after global rate limits reset and new sessions work fine, the wedged session cannot recover. The only workaround is destructive (`/clear` or start over), causing context and plan continuity loss.

Key symptoms:
- Session-local permanent "Rate limit reached" failure after transient limits clear
- Even `/compact` fails, so built-in recovery paths cannot execute
- Users can continue in new sessions, but the wedged session is dead

## Current State

- Lemon has compaction, cron, resume primitives, and auto-resume (PLN-20260303)
- Missing: explicit session self-healing state machine for wedged limiter/backoff states
- Gap: no probe requests, capped backoff reset, fallback provider switching, or safe session forking

## Scope

### In Scope

1. **Probe requests** - Test if rate limit has cleared without affecting user context
2. **Capped backoff reset** - Reset exponential backoff when global quota clears
3. **Fallback model/provider** - Switch to alternative provider when primary is wedged
4. **Safe session fork** - Create new session with context carryover as last resort
5. **Telemetry and observability** - Track healing attempts, successes, and failures
6. **Testing and validation** - Comprehensive test coverage for all healing paths

### Out of Scope

- Global rate limit avoidance (handled by PLN-20260303 auto-resume)
- Provider-side rate limit increases (external dependency)
- Automatic context compaction (separate feature)
- Multi-session orchestration (future enhancement)

## Milestones

### M1 — Probe Request Mechanism

- [ ] Design probe request structure (minimal cost, non-mutating)
- [ ] Implement probe request API for testing rate limit status
- [ ] Add probe retry logic with configurable intervals
- [ ] Track probe history per session
- [ ] Tests: probe success, probe failure, probe timeout, probe history

### M2 — Backoff State Reset

- [ ] Detect when global quota has cleared (via probe or external signal)
- [ ] Implement capped exponential backoff reset logic
- [ ] Add backoff state persistence across session events
- [ ] Integrate with existing rate limit pause system
- [ ] Tests: backoff reset on quota clear, backoff persistence, integration with pause system

### M3 — Fallback Provider Integration

- [ ] Design fallback provider selection strategy (priority list, health-based)
- [ ] Implement provider health checking mechanism
- [ ] Add automatic fallback on persistent rate limit
- [ ] Support fallback model selection within same provider
- [ ] Add fallback telemetry and user notification
- [ ] Tests: fallback trigger, fallback success, fallback failure, health checking

### M4 — Safe Session Fork

- [ ] Design session fork with context carryover
- [ ] Implement context extraction and serialization
- [ ] Create new session with carried-over context
- [ ] Add graceful session handoff (close old, activate new)
- [ ] Support plan and todo continuity across fork
- [ ] Tests: context carryover, plan continuity, todo preservation, handoff

### M5 — Telemetry and Observability

- [ ] Add telemetry events for all healing attempts
- [ ] Implement healing success/failure metrics
- [ ] Create introspection API for healing history
- [ ] Add dashboard/monitoring hooks
- [ ] Document healing events for debugging
- [ ] Tests: telemetry emission, metrics accuracy, API functionality

### M6 — Testing and Validation

- [ ] Unit tests for all healing components (target: 30+ tests)
- [ ] Integration tests for full healing flows
- [ ] Simulation tests for rate limit scenarios
- [ ] Stress tests for rapid healing attempts
- [ ] Documentation and runbooks

## Exit Criteria

- [ ] Sessions can detect when rate limits have cleared via probe requests
- [ ] Exponential backoff resets when global quota clears
- [ ] Automatic fallback to alternative providers when primary is wedged
- [ ] Safe session fork preserves context, plans, and todos
- [ ] All healing attempts emit telemetry for observability
- [ ] Comprehensive test coverage (>80%) for healing logic
- [ ] Documentation complete for operators and users

## Progress Log

| Timestamp | Milestone | Notes |
|-----------|-----------|-------|
| 2026-03-06 | M0 | Plan created, status: planned |

## Related

- Parent idea: [IDEA-20260225-community-rate-limit-session-self-healing](../ideas/IDEA-20260225-community-rate-limit-session-self-healing.md)
- Related plan: [PLN-20260303-rate-limit-auto-resume](PLN-20260303-rate-limit-auto-resume.md) (auto-resume after rate limit reset)
