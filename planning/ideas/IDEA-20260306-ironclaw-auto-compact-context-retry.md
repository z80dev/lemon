---
id: IDEA-20260306-ironclaw-auto-compact-context-retry
title: Auto-Compact and Retry on ContextLengthExceeded
source: ironclaw
source_commit: 6f21cfa
source_tag: v0.13.0
discovered: 2026-03-06
status: proposed
---

# Description
IronClaw v0.13.0 added automatic context compaction and retry when hitting `ContextLengthExceeded` errors. When a model call fails due to context window limits, the system automatically compacts the conversation history (summarizing or truncating) and retries the request rather than failing outright.

**Key behaviors:**
- Detects `ContextLengthExceeded` errors from provider responses
- Automatically compacts context using summarization strategies
- Retries the request with compacted context
- Preserves critical system instructions and recent context

# Lemon Status
- **Current state**: No automatic compaction on context limits
- **Gap analysis**: Lemon handles context limits via explicit token counting but lacks automatic recovery/retry with compaction

# Investigation Notes
- **Complexity estimate**: M
- **Value estimate**: H
- **Open questions**:
  - What compaction strategy preserves task continuity best?
  - Should this be provider-specific or generic?
  - How to handle compaction in multi-turn tool workflows?
  - Telemetry/visibility into when compaction occurs

# Recommendation
**Proceed** - This addresses a real production pain point where long sessions hit context limits and fail. Would improve reliability for long-running coding sessions.

**Implementation sketch:**
1. Add context limit error detection in AI provider responses
2. Implement compaction strategies (summarization, truncation with preservation)
3. Add retry logic with compacted context
4. Emit telemetry events for compaction occurrences
5. Allow configuration of compaction behavior per-session or globally

# References
- IronClaw commit: `6f21cfa` ("fix: auto-compact and retry on ContextLengthExceeded")
- IronClaw release: v0.13.0
