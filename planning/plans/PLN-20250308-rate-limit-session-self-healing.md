---
id: PLN-20250308-rate-limit-session-self-healing
title: Self-Healing Sessions for Persistent Rate-Limit Wedges
status: landed
owner: janitor
workspace: feature/pln-20250308-rate-limit-session-self-healing
change_id: dfd1cf5b
created: 2026-03-08
landed: 2026-03-08
---

# Self-Healing Sessions for Persistent Rate-Limit Wedges

## Summary

Implement a session self-healing state machine to recover from rate-limit wedges where a session gets stuck permanently rate-limited even after global limits reset. This addresses a painful failure mode where users must abandon sessions and lose context.

## Background

- **Source**: Community demand (Claude Code issue #26699)
- **Related Idea**: `IDEA-20260225-community-rate-limit-session-self-healing`
- **Current State**: Lemon has auto-resume after rate-limit reset, but lacks in-session recovery for wedged limiter states

## Problem Statement

When a session hits rate limits:
1. Session-local limiter enters backoff state
2. Even after global quota resets, the session remains wedged
3. `/compact` may also fail due to rate limits
4. Only workaround is `/clear` or new session (context loss)

## Scope

### In Scope

1. **Probe Request Pattern**: Detect when rate limits have cleared via lightweight probe
2. **Backoff State Reset**: Safely reset session-local backoff when global limits clear
3. **Fallback Model/Provider**: Auto-switch to alternative model/provider when primary is wedged
4. **Safe Session Fork**: Create new session with context carryover when recovery fails
5. **Telemetry**: Emit events for healing attempts, successes, failures

### Out of Scope

- Global rate limit tracking (handled by existing ResumeScheduler)
- UI for manual healing trigger
- Cross-session state sharing

## Success Criteria

- [x] Wedged sessions automatically detect when limits clear
- [x] Probe requests don't exacerbate rate limit issues
- [x] Fallback model/provider selection works
- [x] Session fork preserves critical context
- [x] Telemetry events for observability
- [x] Tests cover healing scenarios
- [x] No regression in existing rate limit handling (config tests pass)

## Implementation Plan

### Phase 1: Detection and Probing (M1)

1. Add `RateLimitHealer` module with probe request logic
2. Implement exponential backoff with jitter for probes
3. Add session health check function
4. Create telemetry events for probe attempts

### Phase 2: Recovery Strategies (M2)

1. Implement backoff reset strategy
2. Add fallback model selection (cheaper/smaller model for recovery)
3. Add fallback provider selection
4. Implement strategy selection logic based on failure patterns

### Phase 3: Session Fork (M3)

1. Create session fork with context carryover
2. Preserve critical state (todos, plans, session memory)
3. Add fork notification to user
4. Clean up wedged session

### Phase 4: Integration and Testing (M4)

1. Integrate healer into session lifecycle
2. Add configuration for healing behavior
3. Unit tests for all strategies
4. Integration tests with mock rate limit scenarios
5. Update documentation

## Progress Log

| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-03-08 | janitor | Created plan from IDEA-20260225-community-rate-limit-session-self-healing | Plan created | - |
| 2026-03-08 | z80 | M1: Implemented RateLimitHealer module with probe logic | Complete | `apps/coding_agent/lib/coding_agent/rate_limit_healer.ex` |
| 2026-03-08 | z80 | M1: Added exponential backoff with jitter for probes | Complete | Tests pass |
| 2026-03-08 | z80 | M1: Added session health check function | Complete | `health_check/1` in Session module |
| 2026-03-08 | z80 | M1: Created telemetry events for probe attempts | Complete | 7 telemetry events implemented |
| 2026-03-08 | z80 | M2: Implemented backoff reset strategy | Complete | `RateLimitRecovery.apply_strategy/2` |
| 2026-03-08 | z80 | M2: Added fallback model/provider selection | Complete | `find_fallback_model/2`, `try_fallback_provider/2` |
| 2026-03-08 | z80 | M2: Implemented strategy selection logic | Complete | `select_strategy/1` with failure-based progression |
| 2026-03-08 | z80 | M3: Created session fork with context carryover | Complete | `SessionFork.fork_session/2` |
| 2026-03-08 | z80 | M3: Added fork notification for users | Complete | `build_fork_message/3`, `fork_notification/1` |
| 2026-03-08 | z80 | M3: Added original session cleanup | Complete | `terminate_original_session/2` |
| 2026-03-08 | z80 | M4: Added configuration for healing behavior | Complete | `Config.rate_limit_healing_config/0` |
| 2026-03-08 | z80 | M4: Added RateLimitHealerRegistry to supervision tree | Complete | Updated `application.ex` |
| 2026-03-08 | z80 | All tests pass | Complete | 21 tests in recovery/fork modules |

## Related

- Parent idea: `IDEA-20260225-community-rate-limit-session-self-healing`
- Related work: `PLN-20260303-rate-limit-auto-resume` (auto-resume after rate-limit reset)
- Related: Session management in `apps/coding_agent/`
