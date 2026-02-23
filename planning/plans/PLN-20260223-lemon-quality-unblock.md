---
id: PLN-20260223-lemon-quality-unblock
title: Unblock `mix lemon.quality` (duplicate tests + architecture boundaries)
status: planned
priority_bucket: now
owner: codex
reviewer: codex
branch: feature/pln-20260223-lemon-quality-unblock
created: 2026-02-23
updated: 2026-02-23
roadmap_ref: ROADMAP.md:74
review_doc: planning/reviews/RVW-PLN-20260223-lemon-quality-unblock.md
merge_doc: planning/merges/MRG-PLN-20260223-lemon-quality-unblock.md
decision_docs: []
depends_on:
  - PLN-20260223-ai-test-expansion
---

# Summary

Resolve current `mix lemon.quality` failures so quality gates are green again across duplicate-test-module checks and architecture-boundary checks.

## Scope

- In scope:
  - Remove duplicate test module definitions currently failing the duplicate-module quality gate.
  - Resolve architecture-boundary violations in `apps/market_intel/lib/market_intel/commentary/pipeline.ex`.
  - Re-run and record quality/test evidence.
- Out of scope:
  - New feature work unrelated to quality blockers.
  - Broad market_intel refactors beyond boundary-compliant changes.

## Current Blockers (Baseline)

From `mix lemon.quality` on 2026-02-23:

1. Duplicate test modules:
- `Ai.ModelsTest`
  - `apps/ai/test/ai/models_test.exs`
  - `apps/ai/test/models_test.exs`
- `Ai.Providers.BedrockTest`
  - `apps/ai/test/ai/providers/bedrock_test.exs`
  - `apps/ai/test/providers/bedrock_test.exs`

2. Architecture boundary violations (5):
- `apps/market_intel/lib/market_intel/commentary/pipeline.ex:209`
- `apps/market_intel/lib/market_intel/commentary/pipeline.ex:216`
- `apps/market_intel/lib/market_intel/commentary/pipeline.ex:219`
- `apps/market_intel/lib/market_intel/commentary/pipeline.ex:221`
- `apps/market_intel/lib/market_intel/commentary/pipeline.ex:225`

## Milestones

- [ ] M1 - Duplicate test module cleanup complete.
- [ ] M2 - Architecture-boundary violations in `market_intel` resolved.
- [ ] M3 - `mix lemon.quality` passes cleanly.
- [ ] M4 - Plan review and merge artifacts completed.

## Work Breakdown

- [ ] Decide canonical locations for AI tests and remove/rename duplicates.
- [ ] Update any references affected by test file moves.
- [ ] Refactor `market_intel` commentary pipeline to compliant dependency boundaries.
- [ ] Run targeted tests for changed apps (`ai`, `market_intel`).
- [ ] Run full quality gate and capture evidence.
- [ ] Update planning review/merge artifacts and status transitions.

## Test Matrix

| Layer | Command / Check | Pass Criteria | Owner | Status |
|---|---|---|---|---|
| unit | `mix test apps/ai/test` | AI tests pass after dedupe changes | `codex` | `pending` |
| unit | `mix test apps/market_intel/test` | market_intel tests pass after boundary fix | `codex` | `pending` |
| quality | `mix lemon.quality` | all checks pass | `codex` | `pending` |

## Risks and Mitigations

- Risk: Removing duplicate tests drops useful coverage.
  - Mitigation: preserve assertions by consolidation rather than deletion-only edits.
- Risk: Boundary fix introduces behavior drift in commentary pipeline.
  - Mitigation: keep changes minimal and backstop with targeted tests.

## Progress Log

| Date (UTC) | Actor | Update | Evidence |
|---|---|---|---|
| 2026-02-23 | `codex` | Created quality-unblock plan with current blockers baseline | `mix lemon.quality`, `planning/INDEX.md` |

## Completion Checklist

- [ ] Scope delivered
- [ ] Tests recorded with pass/fail evidence
- [ ] Review artifact completed
- [ ] Merge artifact completed
- [ ] Relevant docs updated
- [ ] Plan status set to `merged`
