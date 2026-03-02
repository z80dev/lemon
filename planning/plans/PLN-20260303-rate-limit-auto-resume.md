---
id: PLN-20260303-rate-limit-auto-resume
title: Auto-Resume Runs After Rate-Limit Reset
owner: janitor
reviewer: codex
status: in_progress
workspace: feature/pln-20260303-rate-limit-auto-resume
change_id: pending
created: 2026-03-03
updated: 2026-03-05
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
- [x] Identify rate limit error patterns across providers (Anthropic, OpenAI, Google, Bedrock)
- [x] Add rate limit metadata extraction (retry-after header, reset window)
- [x] Create `RateLimitPause` struct for tracking pause state

### M2 — Pause/Resume Orchestration
- [x] Add `paused_for_limit` run state to RunGraph
- [x] Implement pause transition with checkpoint creation
- [x] Implement resume trigger after reset window
- [x] Add resume scheduling via cron or internal timer

### M2.5 — RunGraph Integration (M3 from original plan)
- [x] Add `pause_for_limit/2` to RunGraph for pausing runs
- [x] Add `resume_from_limit/1` to RunGraph for resuming runs
- [x] Update `valid_transition?` to allow running <-> paused_for_limit
- [x] Track pause_history in run records for audit trail
- [x] Ensure paused_for_limit is NOT a terminal status
- [x] Add comprehensive tests (9 new tests, all passing)

### M3 — Telemetry and Observability
- [x] Add telemetry events for pause/resume cycles (in RateLimitPause)
- [x] Expose pause state in introspection API (`rate_limit_pause.list`, `rate_limit_pause.get`, `rate_limit_pause.stats`)
- [x] Add metrics: time_paused, resume_count, limit_hits_by_provider (in RateLimitPause.stats/0)

### M4 — User Experience
- [x] Add user notification when run enters paused-for-limit state (PubSub event emitted)
- [x] Add configuration option for auto-resume behavior (`:rate_limit_auto_resume` and `:rate_limit_resume` config)
- [x] Document the feature and configuration (`docs/rate_limit_auto_resume.md`)

### M5 — Testing and Validation
- [x] Unit tests for rate limit detection (20 tests in rate_limit_pause_test.exs)
- [x] Integration tests for pause/resume cycle (14 tests in rate_limit_pause_methods_test.exs)
- [x] Tests for API methods (14 tests)

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
| 2026-03-03 | M2.5 | Added `paused_for_limit` state to RunGraph |
| 2026-03-03 | M2.5 | Implemented `pause_for_limit/2` and `resume_from_limit/1` functions |
| 2026-03-03 | M2.5 | Updated state machine to allow running <-> paused_for_limit transitions |
| 2026-03-03 | M2.5 | Added pause_history tracking for audit trail |
| 2026-03-03 | M2.5 | 9 new RunGraph tests pass (45 total tests in run_graph_test.exs) |
| 2026-03-05 | M2 | Implemented `CodingAgent.ResumeScheduler` GenServer for automatic resume scheduling |
| 2026-03-05 | M2 | 11 ResumeScheduler tests pass, integrates with RateLimitPause |
| 2026-03-05 | M3-M4 | Implemented introspection API methods (`rate_limit_pause.list`, `.get`, `.stats`) |
| 2026-03-05 | M3-M4 | 14 API method tests pass |
| 2026-03-05 | M4 | Added configuration options (`:rate_limit_auto_resume`, `:rate_limit_resume`) |
| 2026-03-05 | M4 | Added user notification via PubSub on pause |
| 2026-03-05 | M4 | Created comprehensive documentation (`docs/rate_limit_auto_resume.md`) |
| 2026-03-05 | M4 | Updated `apps/coding_agent/AGENTS.md` with rate limit feature docs |

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

| 2026-03-03 | M3-M4 | Committed telegram cancel improvements and claude runner env scrubbing |
| 2026-03-03 | M3-M4 | Added CLAUDECODE denylist, capped rate limit sleep at 5s, improved cancel UX |