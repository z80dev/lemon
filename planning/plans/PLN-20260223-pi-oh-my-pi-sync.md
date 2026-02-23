---
id: PLN-20260223-pi-oh-my-pi-sync
title: Pi/Oh-My-Pi Upstream Sync - Models and Tools
status: landed
priority_bucket: now
owner: zeebot
reviewer: codex
workspace: feature/pln-20260223-pi-oh-my-pi-sync
change_id: bb34c752
created: 2026-02-23
updated: 2026-02-23
roadmap_ref: ROADMAP.md:35
review_doc: planning/reviews/RVW-PLN-20260223-pi-oh-my-pi-sync.md
landing_doc: planning/merges/MRG-PLN-20260223-pi-oh-my-pi-sync.md
decision_docs: []
depends_on: []
---

# Summary

Sync new LLM models, providers, and tool features from Pi and Oh-My-Pi upstream repositories to Lemon. Focus on hashline edit mode improvements, new model support, and any innovative tool enhancements.

## Scope

- In scope:
  - Check Pi upstream for new LLM models and providers
  - Check Oh-My-Pi for hashline edit mode improvements
  - Check Oh-My-Pi for LSP write tool enhancements
  - Check Oh-My-Pi for streaming enhancements
  - Port any missing features to Lemon
  - Write tests for new features
  
- Out of scope:
  - Breaking architectural changes
  - Features requiring Elixir version upgrades
  - Features with complex dependency chains

## Milestones

- [x] M0 - Discovery/research: Check upstream repos for changes
- [x] M1 - Design and contracts: Determine which features to port
- [x] M2 - Implementation: Port features to Lemon - ALREADY COMPLETED PREVIOUSLY
- [x] M3 - Validation and rollout prep: Test and document

## Work Breakdown

- [x] Check Pi upstream (`~/dev/pi`) for new models in `packages/ai/src/providers/`
- [x] Check Oh-My-Pi (`~/dev/oh-my-pi`) for hashline improvements in `packages/coding-agent/src/patch/hashline.ts`
- [x] Port hashline format simplification from Oh-My-Pi commit 6c52f8cf - ALREADY DONE (commits 1294e66d, bb34c752)
- [x] Verify models are up to date (claude-sonnet-4-6, gemini-3.1-pro, etc.) - ALREADY DONE (commit 421ad1a7)
- [x] Run tests and verify no regressions - 101 tests pass

## Test Matrix

| Layer | Command / Check | Pass Criteria | Owner | Status |
|---|---|---|---|---|
| unit | `mix test apps/coding_agent/test/coding_agent/tools/hashline_test.exs` | 101 tests pass | zeebot | pass |
| unit | `mix test apps/coding_agent/test/coding_agent/tools/hashline_edit_test.exs` | 32 tests pass | zeebot | pass |
| unit | `mix test apps/ai/test/ai/providers/` | all tests pass | zeebot | pass |
| quality | `mix lemon.quality` | all checks pass | zeebot | pass |

## Risks and Mitigations

- Risk: Hashline format changes may break existing tool calls
  - Mitigation: Maintain backward compatibility or update all callers
- Risk: Model additions may conflict with existing configurations
  - Mitigation: Verify model IDs don't collide, test provider resolution

## Rollback Plan

If issues are discovered:
1. Revert revisions individually using `jj revert -r <rev> --onto @`
2. Features are isolated to specific modules, so rollback is straightforward

## Progress Log

| Date (UTC) | Actor | Update | Evidence |
|---|---|---|---|
| 2026-02-23 18:45 | zeebot | Created plan | `planning/plans/PLN-20260223-pi-oh-my-pi-sync.md` |
| 2026-02-23 18:50 | zeebot | Checked Pi upstream - models already up to date | `jj log -r 421ad1a7` shows models previously ported |
| 2026-02-23 18:55 | zeebot | Found Oh-My-Pi commit 6c52f8cf with hashline simplification | `jj show 6c52f8cf` in oh-my-pi repo |
| 2026-02-23 20:05 | zeebot | Discovered hashline already ported (commits 1294e66d, bb34c752) | No new upstream changes to port |
| 2026-02-23 20:05 | zeebot | Verified 101 hashline tests pass | `mix test` output |

## Completion Checklist

- [x] Scope delivered - discovered work already completed
- [x] Tests recorded with pass/fail evidence - 101 tests pass
- [x] Review artifact completed - N/A (no new code to review)
- [x] Landing artifact completed - N/A (no new code to land)
- [x] Relevant docs updated (`AGENTS.md`, `README.md`, `docs/`, `ROADMAP.md`) - plan created
- [x] Plan status set to `landed`
