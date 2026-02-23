---
id: IDEA-20260223-oh-my-pi-todo-phase-management
title: [Oh-My-Pi] In-Memory Todo Phase Management for ToolSession
source: oh-my-pi
source_commit: 6afd8a6f
discovered: 2026-02-23
status: proposed
---

# Description
Oh-My-Pi refactored todo state management from file-based to in-memory session cache (commit 6afd8a6f). This feature:
- Adds `getTodoPhases()` and `setTodoPhases()` methods to ToolSession API
- Changes todo persistence from `todos.json` files to in-memory session cache
- Syncs todo phases from session branch history during branching/rewriting
- Provides automatic persistence through session mechanism

Key changes in upstream:
- Modified `packages/coding-agent/src/session/agent-session.ts`
- Added todo phase retrieval from session history
- Removed file-based todo loading logic
- Added 9 modified files with 159 insertions, 125 deletions

# Lemon Status
- Current state: **Has different implementation** - Lemon uses ETS-based TodoStore
- Gap analysis:
  - Lemon has `CodingAgent.Tools.TodoStore` - ETS-based per-session storage
  - Lemon's approach is already in-memory (ETS) with fast lookups
  - Lemon has `TodoRead` and `TodoWrite` tools for session todo management
  - Lemon's implementation may be more performant (ETS vs session cache)
  - Oh-My-Pi's approach integrates more deeply with session branching

# Investigation Notes
- Complexity estimate: **L**
- Value estimate: **L** - Lemon's ETS-based approach may be superior
- Open questions:
  1. Does Lemon's TodoStore properly handle session branching/rewriting?
  2. Should Lemon adopt Oh-My-Pi's session-history-based todo sync?
  3. Are there features in Oh-My-Pi's approach that Lemon is missing?
  4. How does Oh-My-Pi's approach handle todo persistence across restarts?

# Recommendation
**Investigate** - Lemon's ETS-based TodoStore is likely more performant, but should verify:
1. Todo state survives session branching correctly
2. Todo persistence works across session lifecycle
3. No race conditions in concurrent todo updates

If all checks pass, no action needed. Lemon's approach is better.

# References
- Oh-My-Pi commit: 6afd8a6f
- Lemon files:
  - `apps/coding_agent/lib/coding_agent/tools/todo_store.ex`
  - `apps/coding_agent/lib/coding_agent/tools/todowrite.ex`
  - `apps/coding_agent/lib/coding_agent/tools/todoread.ex`
