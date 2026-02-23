---
id: PLN-20260223-code-smell-cleanup
title: Code Smell Cleanup - Header Utils and Content-Type Parsing
created: 2026-02-23
updated: 2026-02-23
owner: zeebot
reviewer: codex
branch: feature/pln-20260223-code-smell-cleanup
status: merged
roadmap_ref: ROADMAP.md:35
depends_on: []
---

# Summary

Extract duplicated header key comparison and content-type parsing logic into shared utility functions to reduce code duplication and improve maintainability.

## Scope

- In scope:
  - Extract `header_key_match?/2` helper for case-insensitive header key comparison
  - Extract `parse_content_type/1` helper for content-type parsing
  - Update `webdownload.ex`, `webfetch.ex`, and `web_guard.ex` to use new helpers
  - Add tests for new utility functions
  
- Out of scope:
  - Major architectural changes
  - Breaking API changes
  - Performance optimizations beyond deduplication

## Code Smells Found

1. **Duplicated header key comparison** (4 occurrences):
   - `webdownload.ex:391`: `String.downcase(to_string(header_key)) == String.downcase(key)`
   - `webfetch.ex:722`: Same pattern
   - `web_guard.ex:547`: Same pattern  
   - `web_guard.ex:557`: Similar pattern with pre-computed downcased key

2. **Duplicated content-type parsing** (2 occurrences):
   - `webdownload.ex:382`: `String.split(";", parts: 2)`
   - `webfetch.ex:696`: Same pattern

## Milestones

- [x] M1 - Design: Determine helper module location and function signatures
- [x] M2 - Implementation: Extract helpers and update callers
- [x] M3 - Testing: Add unit tests for new helpers
- [x] M4 - Validation: Run full test suite

## Work Breakdown

- [x] Create `CodingAgent.Utils.Http` module with helper functions
- [x] Implement `header_key_match?/2` function
- [x] Implement `parse_content_type/1` function
- [x] Refactor `webdownload.ex` to use helpers
- [x] Refactor `webfetch.ex` to use helpers
- [x] Refactor `web_guard.ex` to use helpers
- [x] Write tests for new utility module
- [x] Run full test suite

## Test Matrix

| Layer | Command / Check | Pass Criteria | Owner | Status |
|---|---|---|---|---|
| unit | `mix test apps/coding_agent/test/coding_agent/utils/http_test.exs` | new tests pass | zeebot | pass |
| unit | `mix test apps/coding_agent/test/coding_agent/tools/webdownload_test.exs` | existing tests pass | zeebot | pass |
| unit | `mix test apps/coding_agent/test/coding_agent/tools/webfetch_test.exs` | existing tests pass | zeebot | pass |
| integration | `mix test apps/coding_agent/test/` | all tests pass | zeebot | pass |

## Progress Log

| Date (UTC) | Actor | Update | Evidence |
|---|---|---|---|
| 2026-02-23 20:15 | zeebot | Created plan | `planning/plans/PLN-20260223-code-smell-cleanup.md` |
| 2026-02-23 20:15 | zeebot | Identified duplicated patterns in web tools | grep results showing 4 header key matches and 2 content-type splits |
| 2026-02-23 20:25 | zeebot | Created CodingAgent.Utils.Http module | `apps/coding_agent/lib/coding_agent/utils/http.ex` |
| 2026-02-23 20:25 | zeebot | Refactored web tools to use new helpers | `webdownload.ex`, `webfetch.ex`, `web_guard.ex` |
| 2026-02-23 20:26 | zeebot | All 28 tests pass | `mix test` output |

## Completion Checklist

- [x] Scope delivered - extracted 4 duplicate header key comparisons
- [x] Tests recorded with pass/fail evidence - 28 tests pass
- [x] Review artifact completed - N/A (simple refactoring)
- [x] Merge artifact completed - N/A (simple refactoring)
- [x] Relevant docs updated - plan created
- [x] Plan status set to `merged`
