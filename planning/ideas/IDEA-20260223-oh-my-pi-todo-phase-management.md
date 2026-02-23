---
id: IDEA-20260223-oh-my-pi-todo-phase-management
title: [Oh-My-Pi] In-Memory Todo Phase Management for ToolSession
source: oh-my-pi
source_commit: 6afd8a6f
discovered: 2026-02-23
status: completed
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
- Current state: **ALREADY IMPLEMENTED** - Lemon uses superior ETS-based TodoStore
- Implementation details:
  - `CodingAgent.Tools.TodoStore` - ETS-based per-session storage
  - Uses `:coding_agent_todos` ETS table with `read_concurrency: true`
  - `TodoRead` and `TodoWrite` tools for session todo management
  - ETS heir mechanism for table survival across process exits
  - More performant than Oh-My-Pi's session cache approach

# Verification Results

## 1. ETS-Based Storage
✅ **Implemented** - ETS table with concurrent read/write
✅ **Heir mechanism** - Table survives owner process exits
✅ **Public table** - Accessible from any process
✅ **Fast lookups** - O(1) ETS lookups vs session cache traversal

## 2. Todo Tools
✅ **TodoRead** - Read todos from ETS store
✅ **TodoWrite** - Write todos to ETS store
✅ **Session-scoped** - Per-session todo isolation

## 3. Comparison with Oh-My-Pi
| Feature | Oh-My-Pi | Lemon | Status |
|---------|----------|-------|--------|
| In-memory storage | ✅ (session cache) | ✅ (ETS) | Lemon has better performance |
| Session-scoped | ✅ | ✅ | Parity |
| Concurrent access | ⚠️ (session locks) | ✅ (ETS concurrency) | Lemon is better |
| Table survival | ⚠️ (session-bound) | ✅ (heir mechanism) | Lemon is better |
| Persistence | Session-based | ETS + optional persistence | Comparable |

# Recommendation
**No action needed** - Lemon's ETS-based TodoStore is superior to Oh-My-Pi's session cache approach:
- Better performance (ETS vs session cache traversal)
- Better concurrency (read_concurrency/write_concurrency)
- Better fault tolerance (heir mechanism)
- Simpler implementation (no session integration needed)

Lemon's approach is more idiomatic for BEAM/Elixir and provides better performance characteristics.

# References
- Oh-My-Pi commit: 6afd8a6f
- Lemon implementation:
  - `apps/coding_agent/lib/coding_agent/tools/todo_store.ex`
  - `apps/coding_agent/lib/coding_agent/tools/todowrite.ex`
  - `apps/coding_agent/lib/coding_agent/tools/todoread.ex`
