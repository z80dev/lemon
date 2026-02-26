# Review: Long-Running Agent Harnesses and Task Management

## Plan ID
PLN-20260224-long-running-agent-harnesses

## Review Date
2026-02-25

## Reviewer
janitor

## Summary
Milestones M1-M6 are complete. This close-out slice finalized harness coverage with requirements-projection assertions in control-plane introspection tests and documented the long-running harness primitives across coding-agent and control-plane guides.

## Scope Reviewed
- `apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs`
- `apps/coding_agent/AGENTS.md`
- `apps/lemon_control_plane/AGENTS.md`
- `planning/plans/PLN-20260224-long-running-agent-harnesses.md`

## Validation
```bash
mix test apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs
mix test apps/lemon_services/test
mix test --max-failures 1
```

## Quality Checklist
- [x] `sessions.active.list` projects harness todo/checkpoint/requirements data
- [x] `introspection.snapshot` includes harness requirements progress via embedded `activeSessions`
- [x] Harness docs added to `apps/coding_agent/AGENTS.md`
- [x] Harness projection behavior documented in `apps/lemon_control_plane/AGENTS.md`
- [x] Plan milestones and exit criteria updated (M1-M6 complete)

## Notes
- Full umbrella `mix test` remains impacted by pre-existing `apps/lemon_channels` failures in this environment (same unrelated failure cluster seen in prior runs).

## Recommendation
Approve and keep in `ready_to_land` pending final landing commit record.
