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
| PERF-010 | Make XAPI TokenManager non-blocking | MERGED | worktree-agent-a4f1db46 | Agent 2 |
| PERF-011 | Remove Process.sleep from ThreadWorker | MERGED | worktree-agent-a97b35e2 | Agent 3 |
| PERF-012 | Stop normalizing enqueue failure | MERGED | worktree-agent-a91c6cb4 | Agent 4 |
| PERF-013 | Replace eager task fanout in CodingAgent.Parallel | MERGED | worktree-agent-a6d1ba7f | Agent 5 |
| PERF-014 | Centralize background task spawning | MERGED | worktree-agent-ae05cc1b | Agent 6 |
| CTRL-010 | Make control-plane methods self-describing | MERGED | worktree-agent-adc52fa6 | Agent 7 |
| CTRL-011 | Generate registry from method metadata | MERGED | worktree-agent-adc52fa6 | Agent 7 |

## Wave 2 — Architecture boundary correction (sequential, depends on Wave 1)

| Ticket | Description | Status | Depends On |
|--------|-------------|--------|------------|
| ARCH-010 | Core-owned output intent contract | MERGED | ARCH-001, ARCH-003 (done) |
| ARCH-011 | Move delivery semantics into lemon_channels | MERGED | ARCH-010 |
| ARCH-012 | Move Telegram state out of router | MERGED | ARCH-011 |
| ARCH-013 | Canonicalize resume-token in lemon_core | MERGED | ARCH-012 |
| ARCH-014 | Remove thin wrappers | MERGED | ARCH-013 |

## Wave 3 — Store ownership (depends on ARCH-012)

| Ticket | Description | Status | Depends On |
|--------|-------------|--------|------------|
| DATA-010 | Build state-ownership map | MERGED | ARCH-012 |
| DATA-011 | Extract channel state from generic store | MERGED | DATA-010 |
| DATA-012 | Introduce typed stores | MERGED | DATA-011 |

## Wave 4 — Module decomposition (depends on Wave 2)

| Ticket | Description | Status | Depends On |
|--------|-------------|--------|------------|
| MOD-010 | Split Telegram.Transport | MERGED | ARCH-011 |
| MOD-011 | Split Webhook transport | MERGED | ARCH-011 |
| MOD-012 | Split CodingAgent.Session | MERGED | Wave 2 complete |

## Skipped
- CLEAN-010 (lemon_services) — User decision: keep for later use

## Merge Log
| Time | Branch | Ticket(s) | Conflicts? |
|------|--------|-----------|------------|
| — | — | ARCH-002 already done | No |
| Wave1 | worktree-agent-afe8f3fd | ARCH-001+003 | No |
| Wave1 | worktree-agent-a4f1db46 | PERF-010 | No |
| Wave1 | worktree-agent-a97b35e2 | PERF-011 | No |
| Wave1 | worktree-agent-a91c6cb4 | PERF-012 | No |
| Wave1 | worktree-agent-a6d1ba7f | PERF-013 | No |
| Wave1 | worktree-agent-ae05cc1b | PERF-014 | No |
| Wave1 | worktree-agent-adc52fa6 | CTRL-010+011 | No |
| Wave2 | worktree-agent-ac25e581 | ARCH-010 | No |
| Wave2 | worktree-agent-a2e239c6 | ARCH-011 | No (fast-forward) |
| Wave3 | worktree-agent-a1cf5edf | DATA-010 | No |

| — | feature/pln-20260303-rate-limit-auto-resume-m3 | ARCH-013, MOD-010, MOD-011 | No |
| Wave4 | feature/pln-20260303-rate-limit-auto-resume-m3 | MOD-012 | No |
| Wave3 | feature/pln-20260303-rate-limit-auto-resume-m3 | DATA-012 | No |