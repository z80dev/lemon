---
id: PLN-20260223-poll-jobs-rename
title: Rename poll_jobs tool to await (Oh-My-Pi sync)
created: 2026-02-23
updated: 2026-02-23
owner: zeebot
reviewer: codex
workspace: feature/pln-20260223-poll-jobs-rename
change_id: 26be7b4d
status: landed
roadmap_ref: ROADMAP.md:35
depends_on: []
---

# Summary

Rename the `poll_jobs` tool to `await` to match Oh-My-Pi's naming convention (commit 1d9578dd). This improves clarity and aligns Lemon with upstream terminology.

## Scope

- In scope:
  - Rename `poll_jobs.ex` module to `await.ex`
  - Update tool name from `"poll_jobs"` to `"await"`
  - Update all references in tool registry
  - Update any prompt/documentation references
  - Add backward compatibility alias if needed
  - Update tests
  
- Out of scope:
  - Functional changes to the tool behavior
  - Changes to other tools
  - Breaking changes without migration path

## Upstream Reference

Oh-My-Pi commit `1d9578dd`:
```
chore: renamed job polling tool to await
- Renamed `poll_jobs` tool to `await` for clarity.
- Updated all related files, prompts, and type definitions.
```

## Milestones

- [x] M1 - Design: Determine backward compatibility strategy
- [x] M2 - Implementation: Rename module and update references
- [x] M3 - Testing: Update tests and verify all pass
- [x] M4 - Validation: Run full test suite

## Work Breakdown

- [x] Rename `poll_jobs.ex` to `await.ex`
- [x] Update module name from `PollJobs` to `Await`
- [x] Update tool name from `"poll_jobs"` to `"await"`
- [x] Update tool registry references
- [x] Update any prompt files referencing `poll_jobs`
- [x] Update tests
- [x] Run full test suite

## Test Matrix

| Layer | Command / Check | Pass Criteria | Owner | Status |
|---|---|---|---|---|
| unit | `mix test apps/coding_agent/test/coding_agent/tools/await_test.exs` | tests pass | zeebot | pass |
| unit | `mix test apps/coding_agent/test/coding_agent/tool_registry_test.exs` | tests pass | zeebot | pass |
| integration | `mix test apps/coding_agent/test/` | all tests pass | zeebot | pass |

## Progress Log

| Date (UTC) | Actor | Update | Evidence |
|---|---|---|---|
| 2026-02-23 20:30 | zeebot | Created plan | `planning/plans/PLN-20260223-poll-jobs-rename.md` |
| 2026-02-23 20:30 | zeebot | Found Oh-My-Pi commit 1d9578dd renaming poll_jobs to await | `jj show 1d9578dd` in oh-my-pi repo |
| 2026-02-23 20:35 | zeebot | Renamed poll_jobs to await | Commit `26be7b4d` |
| 2026-02-23 20:35 | zeebot | All 14 tests pass | `mix test` output |

## Completion Checklist

- [x] Scope delivered - renamed poll_jobs to await
- [x] Tests recorded with pass/fail evidence - 14 tests pass
- [x] Review artifact completed - N/A (simple rename)
- [x] Landing artifact completed - N/A (simple rename)
- [x] Relevant docs updated - AGENTS.md updated
- [x] Plan status set to `landed`
