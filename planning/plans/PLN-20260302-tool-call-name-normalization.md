---
id: PLN-20260302-tool-call-name-normalization
title: Normalize Whitespace-Padded Tool Call Names Before Dispatch
status: ready_to_land
owner: janitor
created: 2026-03-02
workspace: main
change_id: pending
---

# Summary
Implement dispatch hardening that trims/normalizes tool call names before lookup, preventing avoidable "tool not found" failures when providers emit whitespace-padded names.

# Scope

## In Scope
- Normalize tool call names by trimming whitespace in `AgentCore.Loop.ToolCalls.find_tool/2`
- Normalize tool call names in `CodingAgent.ToolRegistry.get_tool/3`
- Add telemetry for normalized-vs-raw mismatches to track provider quality
- Write tests for the normalization behavior

## Out of Scope
- Unicode whitespace normalization (beyond standard `String.trim/1`)
- Case normalization (tool names are case-sensitive by design)
- Provider adapter-level changes (defense in depth for future)

# Success Criteria
- [x] Tool calls with whitespace-padded names are successfully dispatched
- [x] Telemetry event emitted when normalization occurs
- [x] Tests verify normalization behavior
- [x] All existing tests pass

# Progress Log
| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-03-02 23:00 | janitor | Created plan | - | - |
| 2026-03-02 23:05 | janitor | Read relevant code | Found 2 locations needing normalization | `tool_calls.ex`, `tool_registry.ex` |
| 2026-03-02 23:10 | janitor | Implemented normalization in `find_tool/2` | Added `String.trim/1` + telemetry | `agent_core/loop/tool_calls.ex` |
| 2026-03-02 23:15 | janitor | Implemented normalization in `get_tool/3` | Added `String.trim/1` + telemetry | `coding_agent/tool_registry.ex` |
| 2026-03-02 23:20 | janitor | Added tests for normalization | 5 new tests, all pass | `tool_registry_test.exs` |
| 2026-03-02 23:25 | janitor | Ran full test suite | 33 ToolRegistry + 4 ToolCalls tests pass | - |

# Related
- Source idea: [IDEA-20260227-openclaw-tool-call-name-normalization](../ideas/IDEA-20260227-openclaw-tool-call-name-normalization.md)
- OpenClaw commit: `6b317b1f174d`
