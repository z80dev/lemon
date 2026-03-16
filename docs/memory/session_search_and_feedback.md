# Session Search and Routing Feedback

This document describes the memory subsystem additions planned for milestones
M5 and M6: a durable session-search store and a routing-feedback loop.

## Session Search (M5)

### Goal

Allow agents to search across past runs by semantic content, so that relevant
context from previous sessions can be injected without manually scrolling
through history.

### Components

| Component | Location | Status |
|---|---|---|
| Durable store and ingest pipeline | `LemonCore.SessionStore` | M5-01 |
| `SessionSearch` API | `LemonCore.SessionSearch` | M5-02 |
| `search_memory` tool | `LemonSkills` / tool registry | M5-02 |
| Memory management and retention | `LemonCore.MemoryManager` | M5-03 |
| Performance and correctness guardrails | test suite | M5-04 |

### Feature flag

```toml
[features]
session_search = "off"   # change to "opt-in" during M5 development
```

## Routing Feedback (M6)

### Goal

Track the outcome of each run (success, failure, human-corrected, etc.) and use
that signal to improve future routing decisions — which engine, model, or skill
set is best for a given task fingerprint.

### Components

| Component | Location | Status |
|---|---|---|
| Explicit run outcome model | `LemonCore.RunOutcome` | M6-01 |
| Task fingerprinting and feedback store | `LemonCore.RoutingFeedback` | M6-02 |
| Feedback reporting and offline evaluation | `LemonCore.FeedbackReport` | M6-03 |
| History-aware routing tie-breakers | `LemonRouter.ModelSelection` | M7-01 |

### Feature flag

```toml
[features]
routing_feedback = "off"   # change to "opt-in" during M6 development
```

## Data ownership

Both features write to the memory lane (see `docs/contributor/ownership.md`).
Schema changes require review from `@lemon/memory` and `@z80`.
