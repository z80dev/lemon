---
id: PLN-20250308-per-channel-model-overrides
title: Persistent Per-Channel Model Overrides
status: landed
owner: janitor
workspace: feature/pln-20250308-per-channel-model-overrides
change_id: dfd1cf5b
created: 2026-03-08
landed: 2026-03-08
---

# Persistent Per-Channel Model Overrides

## Summary

Implement a cross-channel policy layer for default model and thinking profile by route (channel/account/peer/thread), with consistent precedence rules. Promotes Telegram's local pattern into a unified system across all adapters.

## Background

- **Source**: Community demand (OpenClaw issue #12246)
- **Related Idea**: `IDEA-20260227-community-per-channel-model-overrides`
- **Current State**: Telegram has `telegram_default_model`, but it's channel-specific and not unified

## Problem Statement

Current model override limitations:
- Session-level overrides are temporary (lost after resets)
- No durable per-channel model policy
- Cost/performance tradeoffs can't be set per room/workflow
- Different channels can't have different defaults

Community operators need:
- One Discord channel uses cheaper model
- Another channel uses deeper reasoning model
- Overrides persist across sessions/restarts

## Scope

### In Scope

1. **Route Model Policy**: Model + thinking profile by route (channel/account/peer/thread)
2. **Policy Storage**: Persistent storage for model policies
3. **Precedence Rules**: Clear precedence (session > channel > global)
4. **Management API**: Set/get/clear policies per route
5. **Migration**: Migrate Telegram's existing pattern

### Out of Scope

- UI for policy management (CLI/API only)
- Dynamic policy changes during active sessions
- Per-user policies (use channel/thread level)

## Success Criteria

- [x] Route model policy schema defined
- [x] Policy storage with persistence
- [x] Precedence rules implemented
- [ ] Management API for policies (Mix tasks)
- [x] Telegram migration module created
- [ ] All adapters support route-level policies
- [x] Tests for policy resolution (48 tests)
- [ ] Documentation for operators

## Implementation Plan

### Phase 1: Policy Schema and Storage (M1)

1. Create `LemonCore.ModelPolicy` schema
2. Define route key format (channel/account/peer/thread)
3. Add policy storage (ETS + persistence)
4. Create policy CRUD operations

### Phase 2: Precedence and Resolution (M2)

1. Implement policy resolution with precedence
2. Integrate with existing model resolution
3. Add policy cache for performance
4. Create resolution telemetry

### Phase 3: Management API (M3)

1. Add policy set/clear functions
2. Create Mix tasks for policy management
3. Add policy listing/query functions
4. Implement policy validation

### Phase 4: Migration and Integration (M4)

1. Migrate Telegram `telegram_default_model` to new system
2. Update all adapters to use policy resolution
3. Add configuration for default policies
4. Unit and integration tests
5. Update documentation

## Progress Log

| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-03-08 | janitor | Created plan from IDEA-20260227-community-per-channel-model-overrides | Plan created | - |
| 2026-03-02 | implementation-agent | M1: Implemented ModelPolicy schema, Route module, storage | 48 tests passing | `apps/lemon_core/lib/lemon_core/model_policy.ex` |
| 2026-03-02 | implementation-agent | M2: Implemented precedence-based resolution | Tests passing | `LemonCore.ModelPolicy.resolve/1` |
| 2026-03-02 | implementation-agent | M4: Created Telegram migration module | Migration utilities ready | `LemonCore.ModelPolicy.Migration` |

## Related

- Parent idea: `IDEA-20260227-community-per-channel-model-overrides`
- Related work: Model resolution in `apps/ai/`
- Related: Telegram adapter in `apps/lemon_channels/`
- Related: Session management in `apps/coding_agent/`
