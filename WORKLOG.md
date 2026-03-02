# Architecture Fix Worklog

Coordination file for the archfix.md implementation.

## Status Legend
- `PENDING` — Not started
- `IN_PROGRESS` — Agent working in worktree
- `MERGED` — Worktree merged to main branch
- `BLOCKED` — Waiting on dependency

## Wave 1 — Parallel (no dependencies)

| Ticket | Description | Status | Branch | Agent |
|--------|-------------|--------|--------|-------|
| ARCH-001 | Sync architecture policy with real app inventory | MERGED | worktree-agent-afe8f3fd | Agent 1 |
| ARCH-002 | Remove games-platform duplicate | MERGED | — | Already done (2d41af25) |
| ARCH-003 | Add router/channels tripwire tests | MERGED | worktree-agent-afe8f3fd | Agent 1 |
| PERF-010 | Make XAPI TokenManager non-blocking | IN_PROGRESS | worktree-agent-a4f1db46 | Agent 2 |
| PERF-011 | Remove Process.sleep from ThreadWorker | IN_PROGRESS | worktree-agent-a97b35e2 | Agent 3 |
| PERF-012 | Stop normalizing enqueue failure | IN_PROGRESS | worktree-agent-a91c6cb4 | Agent 4 |
| PERF-013 | Replace eager task fanout in CodingAgent.Parallel | IN_PROGRESS | worktree-agent-a6d1ba7f | Agent 5 |
| PERF-014 | Centralize background task spawning | IN_PROGRESS | worktree-agent-ae05cc1b | Agent 6 |
| CTRL-010 | Make control-plane methods self-describing | IN_PROGRESS | worktree-agent-adc52fa6 | Agent 7 |
| CTRL-011 | Generate registry from method metadata | IN_PROGRESS | worktree-agent-adc52fa6 | Agent 7 |

## Wave 2 — Architecture boundary correction (sequential, depends on Wave 1)

| Ticket | Description | Status | Depends On |
|--------|-------------|--------|------------|
| ARCH-010 | Core-owned output intent contract | BLOCKED | ARCH-001, ARCH-003 |
| ARCH-011 | Move delivery semantics into lemon_channels | BLOCKED | ARCH-010 |
| ARCH-012 | Move Telegram state out of router | BLOCKED | ARCH-011 |
| ARCH-013 | Canonicalize resume-token in lemon_core | BLOCKED | ARCH-012 |
| ARCH-014 | Remove thin wrappers | BLOCKED | ARCH-013 |

## Wave 3 — Store ownership (depends on ARCH-012)

| Ticket | Description | Status | Depends On |
|--------|-------------|--------|------------|
| DATA-010 | Build state-ownership map | BLOCKED | ARCH-012 |
| DATA-011 | Extract channel state from generic store | BLOCKED | DATA-010 |
| DATA-012 | Introduce typed stores | BLOCKED | DATA-011 |

## Wave 4 — Module decomposition (depends on Wave 2)

| Ticket | Description | Status | Depends On |
|--------|-------------|--------|------------|
| MOD-010 | Split Telegram.Transport | BLOCKED | ARCH-011 |
| MOD-011 | Split Webhook transport | BLOCKED | ARCH-011 |
| MOD-012 | Split CodingAgent.Session | BLOCKED | Wave 2 complete |

## Skipped
- CLEAN-010 (lemon_services) — User decision: keep for later use

## Merge Log
| Time | Branch | Ticket(s) | Conflicts? |
|------|--------|-----------|------------|
| — | — | ARCH-002 already done | No |
| Wave1 | worktree-agent-afe8f3fd | ARCH-001+003 | No |
