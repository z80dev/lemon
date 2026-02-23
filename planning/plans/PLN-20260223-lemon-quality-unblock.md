---
id: PLN-20260223-lemon-quality-unblock
title: Unblock `mix lemon.quality` (duplicate tests + architecture boundaries)
status: merged
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

- [x] M1 - Duplicate test module cleanup complete.
- [x] M2 - Architecture-boundary violations in `market_intel` resolved.
- [x] M3 - `mix lemon.quality` passes cleanly.
- [x] M4 - Plan review and merge artifacts completed.

## Work Breakdown

- [x] Decide canonical locations for AI tests and remove/rename duplicates.
- [x] Update any references affected by test file moves.
- [x] Refactor `market_intel` commentary pipeline to compliant dependency boundaries.
- [x] Run targeted tests for changed apps (`ai`, `market_intel`).
- [x] Run full quality gate and capture evidence.
- [x] Update planning review/merge artifacts and status transitions.

## Test Matrix

| Layer | Command / Check | Pass Criteria | Owner | Status |
|---|---|---|---|---|
| unit | `mix test apps/ai/test/models_test.exs apps/ai/test/providers/bedrock_test.exs` | AI duplicate-module cleanup remains green | `codex` | `passed` |
| unit | `mix test apps/agent_core/test/agent_core/text_generation_test.exs` | `AgentCore.TextGeneration` bridge helper behavior passes | `codex` | `passed` |
| unit | `mix test apps/market_intel/test/market_intel/commentary/pipeline_test.exs` | market_intel boundary-compliant generation path passes | `codex` | `passed` |
| quality | `mix lemon.quality` | all checks pass | `codex` | `passed` |

## Risks and Mitigations

- Risk: Removing duplicate tests drops useful coverage.
  - Mitigation: preserve assertions by consolidation rather than deletion-only edits.
- Risk: Boundary fix introduces behavior drift in commentary pipeline.
  - Mitigation: keep changes minimal and backstop with targeted tests.

## Progress Log

| Date (UTC) | Actor | Update | Evidence |
|---|---|---|---|
| 2026-02-23 | `codex` | Created quality-unblock plan with current blockers baseline | `mix lemon.quality`, `planning/INDEX.md` |
| 2026-02-23 | `codex` | Renamed legacy duplicate modules (`Ai.ModelsLegacyTest`, `Ai.Providers.BedrockLegacyTest`) to preserve coverage while clearing duplicate-module failures | `apps/ai/test/models_test.exs`, `apps/ai/test/providers/bedrock_test.exs` |
| 2026-02-23 | `codex` | Moved `market_intel` AI completion behind `AgentCore.TextGeneration.complete_text/4` and added helper tests | `apps/agent_core/lib/agent_core/text_generation.ex`, `apps/agent_core/test/agent_core/text_generation_test.exs`, `apps/market_intel/lib/market_intel/commentary/pipeline.ex` |
| 2026-02-23 | `codex` | Updated relevant AGENTS docs for the new boundary-compliant generation path | `apps/agent_core/AGENTS.md`, `apps/market_intel/AGENTS.md` |
| 2026-02-23 | `codex` | Verified targeted tests and full quality gate are passing | `mix test apps/ai/test/models_test.exs apps/ai/test/providers/bedrock_test.exs`, `mix test apps/agent_core/test/agent_core/text_generation_test.exs`, `mix test apps/market_intel/test/market_intel/commentary/pipeline_test.exs`, `mix lemon.quality` |

## Completion Checklist

- [x] Scope delivered
- [x] Tests recorded with pass/fail evidence
- [x] Review artifact completed
- [x] Merge artifact completed
- [x] Relevant docs updated
- [ ] Plan status set to `merged`
