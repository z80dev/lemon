# Review: Long-Running Agent Harnesses and Task Management

## Plan ID
PLN-20260224-long-running-agent-harnesses

## Review Date
2026-02-25

## Reviewer
janitor

## Summary

Milestones M1-M6 are complete. The harness now includes:

- feature requirement generation + persistence
- dependency-aware todo progress tracking
- checkpoint/resume support
- unified session progress snapshots
- control-plane/introspection integration via `agent.progress`

M6 close-out adds operator docs and planning artifacts for landing.

## Milestone Review

| Milestone | Status | Notes |
|---|---|---|
| M1 — Feature requirements generation | ✅ Complete | `CodingAgent.Tools.FeatureRequirements` + tests |
| M2 — Todo dependencies/progress | ✅ Complete | `CodingAgent.Tools.TodoStore` enhancements + tests |
| M3 — Checkpoint/resume | ✅ Complete | `CodingAgent.Checkpoint` + tests |
| M4 — Progress reporting | ✅ Complete | `CodingAgent.Progress.snapshot/2` + tests |
| M5 — Introspection integration | ✅ Complete | `agent.progress` method, schema/registry wiring, introspection events |
| M6 — Tests and documentation | ✅ Complete | Added docs + AGENTS references + this review/merge artifact set |

## Validation

```bash
mix test apps/coding_agent/test/coding_agent/checkpoint_test.exs \
  apps/coding_agent/test/coding_agent/tools/todo_store_test.exs \
  apps/coding_agent/test/coding_agent/tools/feature_requirements_test.exs \
  apps/coding_agent/test/coding_agent/progress_test.exs \
  apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs
# 109 tests, 0 failures
```

## Recommendation

Approve and keep in `ready_to_land` pending operator landing sequence.
