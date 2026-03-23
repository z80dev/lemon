# Router PR2 Implementation Notes

## Scope

PR2 keeps the router queue-path refactor narrow:

- `SessionTransitions` remains the pure owner of queue mutation and queue policy.
- `SessionCoordinator` interprets reducer-produced effects and owns process, registry, cancel, steer, and router-phase IO.
- `RunStarter` owns the shared child-start mechanics for prepared `%LemonRouter.Submission{}` values.

## Non-goals

- No reducer rename in this slice.
- No `%Job{}` compatibility removal.
- No gateway queue-semantics redesign.
- No new router phase kinds or steer-phase semantics.

## Notes

- `RunStarter` deliberately does not emit phases and does not touch session registries.
- `SessionCoordinator` still emits router-owned phases so PR1 ordering stays intact.
- `RunOrchestrator.start_run_process/4` stays behavior-compatible while delegating the actual child start.
