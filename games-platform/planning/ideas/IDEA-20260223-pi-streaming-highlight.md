---
id: IDEA-20260223-pi-streaming-highlight
title: [Pi] Incremental Highlight for Streaming Write Tool Calls
source: pi
source_commit: 0c61dd58
discovered: 2026-02-23
status: proposed
---

# Description
Pi added incremental syntax highlighting for streaming write tool calls (commit 0c61dd58). This feature:
- Provides real-time syntax highlighting as code is streamed
- Updates TUI to show highlighted code during write operations
- 147 lines of new code in interactive mode components

Key changes in upstream:
- Modified `packages/coding-agent/src/modes/interactive/components/tool-execution.ts`
- Added incremental highlight logic for streaming content
- Enhances UX during code generation

# Lemon Status
- Current state: **Doesn't have** - Lemon TUI may not have this feature
- Gap analysis:
  - Lemon has TUI in `clients/lemon-tui/`
  - Has streaming support but may lack incremental highlighting
  - Would require TypeScript/Node.js TUI changes
  - Enhances perceived responsiveness during code writes

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **L** - Nice UX improvement, not critical
- Open questions:
  1. Does Lemon's TUI currently support syntax highlighting at all?
  2. How does Lemon's TUI handle streaming tool output?
  3. What highlighting library does Pi use?
  4. Is this worth the implementation effort for Lemon?

# Recommendation
**Defer** - Nice-to-have UX improvement. Lower priority than functional features. Consider as part of broader TUI enhancement effort.

# References
- Pi commit: 0c61dd58
- Lemon files:
  - `clients/lemon-tui/src/` - TUI implementation
