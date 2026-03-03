---
id: PLN-20250308-auto-compact-context-retry
title: Auto-Compact and Retry on ContextLengthExceeded
status: in_progress
owner: janitor
workspace: feature/pln-20250308-auto-compact-context-retry
change_id: pending
created: 2026-03-08
---

# Auto-Compact and Retry on ContextLengthExceeded

## Summary

Implement automatic context compaction and retry when AI provider calls fail with `ContextLengthExceeded` errors. When a model call exceeds the context window limit, the system will automatically compact the conversation history (using summarization strategies) and retry the request rather than failing outright.

This addresses a real production pain point where long coding sessions hit context limits and fail, forcing users to manually compact or start fresh.

## Background

- **Source**: IronClaw v0.13.0 (commit `6f21cfa`)
- **Related Idea**: `IDEA-20260306-ironclaw-auto-compact-context-retry`
- **Current State**: Lemon handles context limits via explicit token counting but lacks automatic recovery/retry with compaction

## Scope

### In Scope

1. **Error Detection**: Detect `ContextLengthExceeded` errors from provider responses (Anthropic, OpenAI, Google, Bedrock)
2. **Compaction Strategies**: Implement configurable strategies for context reduction:
   - Summarization of older messages (using a cheaper/faster model)
   - Truncation with preservation of critical context (system instructions, recent messages, tool results)
   - Hybrid approach (summarize middle, preserve beginning and end)
3. **Retry Logic**: Automatic retry with compacted context
4. **Telemetry**: Emit events for compaction occurrences, strategy used, tokens saved
5. **Configuration**: Per-session and global configuration for compaction behavior
6. **Safety Limits**: Maximum compaction attempts, minimum preserved context threshold

### Out of Scope

- Multi-turn tool workflow state preservation (covered by existing session management)
- Provider-specific token counting optimization (use existing `Ai.TokenCounter`)
- UI/visual feedback for compaction (can be added later)

## Success Criteria

- [ ] Context limit errors are automatically detected across all providers
- [ ] At least 2 compaction strategies implemented (summarization + truncation)
- [ ] Retry with compacted context succeeds for typical long-session scenarios
- [ ] Telemetry events emitted for observability
- [ ] Configuration options documented
- [ ] Tests cover compaction scenarios (unit + integration)
- [ ] No regression in existing context handling

## Implementation Plan

### Phase 1: Error Detection and Infrastructure (M1)

1. Add `ContextLengthExceeded` error type to `Ai.Provider` behavior
2. Update all providers to detect and return this error type
3. Create `Ai.ContextCompactor` module with strategy behavior
4. Add configuration schema for compaction settings

### Phase 2: Compaction Strategies (M2)

1. Implement `SummarizationStrategy` - uses lightweight model to summarize older messages
2. Implement `TruncationStrategy` - removes oldest messages while preserving critical context
3. Implement `HybridStrategy` - combines both approaches
4. Add token counting integration for pre-compaction estimation

### Phase 3: Retry Integration (M3)

1. Integrate compaction into `Ai.Client` request flow
2. Add retry loop with compaction trigger
3. Implement safety limits (max attempts, minimum context)
4. Add telemetry emission points

### Phase 4: Testing and Documentation (M4)

1. Unit tests for each compaction strategy
2. Integration tests with mock provider responses
3. Update AGENTS.md and relevant docs
4. Create review artifact

## Progress Log

| Timestamp | Who | What | Result | Links |
|-----------|-----|------|--------|-------|
| 2026-03-08 | janitor | Created plan from IDEA-20260306-ironclaw-auto-compact-context-retry | Plan created | - |
| 2026-03-08 | janitor | M1: Error detection - Added `context_length_error?/1` to `Ai.Error` | Complete | `apps/ai/lib/ai/error.ex` |
| 2026-03-08 | janitor | M2: Created `Ai.ContextCompactor` with truncation strategy | Complete | `apps/ai/lib/ai/context_compactor.ex` |
| 2026-03-08 | janitor | M2: Created `Ai.CompactingClient` for automatic retry | Complete | `apps/ai/lib/ai/compacting_client.ex` |
| 2026-03-08 | janitor | M4: Added comprehensive tests for ContextCompactor | Complete | `apps/ai/test/ai/context_compactor_test.exs` |
| 2026-03-08 | janitor | All tests pass (18 new tests, 0 failures) | Complete | - |

## Related

- Parent idea: `IDEA-20260306-ironclaw-auto-compact-context-retry`
- Related work: Context management in `apps/ai/lib/ai/`
- Related: Token counting in `Ai.TokenCounter`
