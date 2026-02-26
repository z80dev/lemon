---
id: IDEA-20260223-ironclaw-context-compaction
title: [IronClaw] Auto-Compact and Retry on ContextLengthExceeded
source: ironclaw
source_commit: 6f21cfa
discovered: 2026-02-23
status: completed
---

# Description
IronClaw added automatic compaction and retry when LLM returns context-length-exceeded error (commit 6f21cfa). This feature:
- Automatically compacts conversation history when context limit hit
- Retries once after compaction instead of failing
- Keeps system messages, last user message, and current turn's tool calls
- Adds note to inform LLM that earlier context was dropped
- 267 lines of new code in dispatcher

Key changes in upstream:
- Modified `src/agent/dispatcher.rs`
- Added compaction logic with retry mechanism
- Handles retry failure gracefully (returns original error)

# Lemon Status
- Current state: **ALREADY IMPLEMENTED** - Lemon has comprehensive overflow recovery
- Implementation details:
  - `CodingAgent.Session` has full overflow recovery state machine (lines 112-120, 724-732)
  - `overflow_recovery_in_progress`, `overflow_recovery_attempted` tracking
  - `continue_after_overflow_compaction/1` handles automatic retry (lines 2655-2670)
  - Shows "Retrying after compaction..." message to user
  - Calls `AgentCore.Agent.continue/1` to resume after compaction
  - Telemetry events for success/failure tracking
  - Extensive test coverage in `session_overflow_recovery_test.exs`

# Verification Results

## 1. Automatic Compaction
✅ **Implemented** - `CodingAgent.Compaction.compact/3` handles context compaction
✅ **Triggered** - Auto-compaction when context window threshold reached
✅ **Summary generation** - LLM generates summary of compacted content

## 2. Automatic Retry
✅ **Implemented** - `continue_after_overflow_compaction/1` automatically retries
✅ **User notification** - Shows "Retrying after compaction..." message
✅ **Error handling** - Graceful failure if retry fails
✅ **Telemetry** - Events emitted for success/failure tracking

## 3. Comparison with IronClaw
| Feature | IronClaw | Lemon | Status |
|---------|----------|-------|--------|
| Auto-compact on overflow | ✅ | ✅ | Parity |
| Retry after compaction | ✅ | ✅ | Parity |
| Keep system messages | ✅ | ✅ | Parity |
| Keep last user message | ✅ | ✅ | Parity |
| Add context-dropped note | ✅ | ✅ | Parity (via compaction summary) |
| Telemetry/observability | Basic | Extensive | Lemon has more |
| Test coverage | Basic | Comprehensive | Lemon has more |

# Recommendation
**No action needed** - Lemon already has full parity with IronClaw's context compaction and retry feature, with more comprehensive state tracking and telemetry.

# References
- IronClaw commit: 6f21cfa
- Lemon implementation:
  - `apps/coding_agent/lib/coding_agent/session.ex` - Overflow recovery state machine
  - `apps/coding_agent/lib/coding_agent/compaction.ex` - Compaction logic
  - `apps/coding_agent/test/coding_agent/session_overflow_recovery_test.exs` - Tests
