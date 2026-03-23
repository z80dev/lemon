# Router PR2 Implementation

Scope for this slice:

- add a tiny typed reducer effect surface in `LemonRouter.QueueEffect`
- extract shared child-start mechanics into `LemonRouter.RunStarter`
- keep `LemonRouter.SessionTransitions` pure over `%LemonRouter.Submission{}`
- keep `LemonRouter.SessionCoordinator` as the interpreter for reducer effects, registry updates, phase emission, and cancellation IO
- remove duplicated run-start logic from `SessionCoordinator` and `RunOrchestrator`

Constraints:

- preserve existing queue semantics and PR1 phase ordering
- do not redesign steer semantics or gateway ownership
- keep `%Submission{}` as the router-internal contract
- keep `%Job{}` compatibility untouched
- keep phase emission out of `RunStarter`

Validation target:

- focused router tests
- `mix lemon.quality`
