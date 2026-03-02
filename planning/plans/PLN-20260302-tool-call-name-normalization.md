---
id: PLN-20260302-tool-call-name-normalization
title: Tool Call Name Normalization for Provider Formatting Drift
status: ready_to_land
owner: janitor
reviewer: janitor
branch: feature/pln-20260302-tool-call-name-normalization
created: 2026-03-02
---

# Tool Call Name Normalization for Provider Formatting Drift

## Goal

Implement dispatch hardening that normalizes tool call names before lookup, preventing avoidable "tool not found" failures when providers emit whitespace-padded names.

## Motivation

OpenClaw added dispatch hardening that trims/normalizes tool call names before lookup. Lemon currently validates non-empty tool-call names (`String.trim(name) != ""`) but dispatch still uses exact matching. This creates brittle behavior when upstream model outputs include accidental padding or non-canonical casing.

## Milestones

- [x] **M1** — Implement `normalize_tool_name/1` function
  - Trim leading/trailing whitespace
  - Normalize Unicode whitespace (non-breaking space, en/em space, etc.)
  - Collapse internal whitespace sequences to single space

- [x] **M2** — Update `find_tool/2` to use normalized matching
  - Compare normalized tool names instead of exact match
  - Emit telemetry when normalization is needed for diagnostics

- [x] **M3** — Add comprehensive tests
  - Test whitespace-padded tool names
  - Test internal whitespace normalization
  - Test Unicode whitespace handling
  - Test "not found" behavior after normalization

- [x] **M4** — Documentation and review
  - Update AGENTS.md if needed
  - Create review artifact
  - Create merge artifact

## Scope

### In Scope
- Tool name normalization in `AgentCore.Loop.ToolCalls`
- Telemetry emission for normalized matches
- Unit tests for normalization edge cases

### Out of Scope
- Case-insensitive matching (preserve exact case)
- Provider adapter-level normalization (defense in depth can be added later)
- Tool name aliases or fuzzy matching

## Success Criteria

- [x] Tool calls with leading/trailing whitespace are matched correctly
- [x] Tool calls with internal Unicode whitespace are normalized and matched
- [x] Telemetry is emitted when normalization occurs
- [x] All existing tests continue to pass
- [x] New tests cover normalization scenarios

## Test Strategy

- Unit tests for `normalize_tool_name/1` function
- Integration tests via `execute_and_collect_tools/6` with padded names
- Regression test: ensure exact matches still work (no false positives)

## Progress Log

| Timestamp | Milestone | Note |
|-----------|-----------|------|
| 2026-03-02T22:00 | M1 | Implemented `normalize_tool_name/1` with Unicode whitespace support |
| 2026-03-02T22:01 | M2 | Updated `find_tool/2` to use normalized matching with telemetry |
| 2026-03-02T22:03 | M3 | Added 4 comprehensive tests, all passing |
| 2026-03-02T22:05 | M4 | Created review and merge artifacts, moved to ready_to_land |
