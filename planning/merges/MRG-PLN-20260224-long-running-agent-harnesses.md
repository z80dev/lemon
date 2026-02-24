---
plan_id: PLN-20260224-long-running-agent-harnesses
status: ready_to_land
prepared_at: 2026-02-25
prepared_by: janitor
---

# Merge Record: Long-Running Agent Harnesses and Task Management

## Summary

This merge record captures completion of `PLN-20260224-long-running-agent-harnesses` through M6.
The long-running harness stack now supports feature planning, dependency-aware execution, checkpoint/resume, and introspectable progress snapshots.

## Delivered

- `CodingAgent.Tools.FeatureRequirements` for requirement-file generation and feature progress
- `CodingAgent.Tools.TodoStore` dependency/progress enhancements
- `CodingAgent.Checkpoint` checkpoint/resume persistence
- `CodingAgent.Progress.snapshot/2` aggregation API
- `agent.progress` control-plane method + schema + registry integration
- `:agent_progress_snapshot` introspection event emission
- Operator docs:
  - `docs/long-running-agent-harnesses.md`
  - `apps/coding_agent/AGENTS.md` updates
  - `apps/lemon_control_plane/AGENTS.md` updates

## Validation

- `mix test apps/coding_agent/test/coding_agent/checkpoint_test.exs apps/coding_agent/test/coding_agent/tools/todo_store_test.exs apps/coding_agent/test/coding_agent/tools/feature_requirements_test.exs apps/coding_agent/test/coding_agent/progress_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs` ✅ (109 tests)

## Related

- Plan: `planning/plans/PLN-20260224-long-running-agent-harnesses.md`
- Review: `planning/reviews/RVW-PLN-20260224-long-running-agent-harnesses.md`
