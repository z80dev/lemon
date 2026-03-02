---
id: PLN-20260303-rate-limit-auto-resume
title: Auto-Resume Runs After Rate-Limit Reset
owner: janitor
reviewer: codex
status: in_progress
workspace: feature/pln-20260303-rate-limit-auto-resume
change_id: pending
created: 2026-03-03
updated: 2026-03-03
---

## Goal

Implement auto-resume functionality for coding agent runs that hit provider rate limits. When a session encounters a rate limit, instead of failing permanently, the system should:
1. Enter a "paused-for-limit" state
2. Automatically resume after the rate limit reset window
3. Provide telemetry and user visibility into the pause/resume cycle

## Background

Community requests (Claude Code #26789) highlight a specific pain point: when coding sessions hit provider limits, users want an "auto-continue when limit resets" mode so work resumes without manual intervention. This compounds value from Lemon's existing checkpoint + automation foundations.

## Current State

- Lemon has primitives: cron scheduling, checkpointing (M3 complete in harnesses), watchdogs, resumable sessions
- Missing: first-class "paused-for-limit" state with built-in delayed resume trigger
- Existing rate limit handling returns hard errors; no retry orchestration

## Milestones

### M1 — Rate Limit Detection and State Tracking
- [ ] Identify rate limit error patterns across providers (Anthropic, OpenAI, Google, Bedrock)
- [ ] Add rate limit metadata extraction (retry-after header, reset window)
- [ ] Create `RateLimitPause` struct for tracking pause state

### M2 — Pause/Resume Orchestration
- [ ] Add `paused_for_limit` run state to RunGraph
- [ ] Implement pause transition with checkpoint creation
- [ ] Implement resume trigger after reset window
- [ ] Add resume scheduling via cron or internal timer

### M3 — Telemetry and Observability
- [ ] Add telemetry events for pause/resume cycles
- [ ] Expose pause state in introspection API
- [ ] Add metrics: time_paused, resume_count, limit_hits_by_provider

### M4 — User Experience
- [ ] Add user notification when run enters paused-for-limit state
- [ ] Add configuration option for auto-resume behavior
- [ ] Document the feature and configuration

### M5 — Testing and Validation
- [ ] Unit tests for rate limit detection
- [ ] Integration tests for pause/resume cycle
- [ ] Test with mocked provider rate limit responses

### M6 — Review and Landing
- [ ] Code review
- [ ] Documentation review
- [ ] Merge to main

## Exit Criteria

- [ ] Rate limit errors trigger pause state instead of hard failure
- [ ] Runs automatically resume after reset window
- [ ] Telemetry provides visibility into pause/resume cycles
- [ ] Users can configure auto-resume behavior
- [ ] All tests pass
- [ ] Documentation complete

## Progress Log

| Timestamp | Milestone | Notes |
|-----------|-----------|-------|
| 2026-03-03 | M1-M2 | Implemented `CodingAgent.RateLimitPause` module with ETS-backed pause tracking |
| 2026-03-03 | M1-M2 | Added create/get/resume/list/stats/cleanup functions with telemetry |
| 2026-03-03 | M1-M2 | 20 comprehensive tests pass |

## Implementation Notes

### M1-M2: Rate Limit Pause Tracking

Created `CodingAgent.RateLimitPause` module:

**Core Functions:**
- `create/4` - Creates pause record with retry-after timing
- `ready_to_resume?/1` - Checks if pause window has elapsed
- `resume/1` - Marks pause as resumed with telemetry
- `get/1` - Fetches pause by ID
- `list_pending/1` - Lists active pauses for session
- `list_all/1` - Lists all pauses for session
- `stats/0` - Aggregate statistics across all pauses
- `cleanup_expired/1` - Removes old pause records

**Features:**
- ETS-backed in-memory storage with concurrent access
- Telemetry events: `[:coding_agent, :rate_limit_pause, :paused|:resumed]`
- Automatic resume_at calculation from retry_after_ms
- Provider-specific tracking and statistics

**Tests:** 20 tests covering all functionality
