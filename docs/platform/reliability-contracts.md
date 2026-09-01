# Reliability Contracts

What each seam between the platform's apps promises when something goes
wrong, and how the promise is enforced. This is the deliverable of Phase 2 of
the [September 2026 architecture review](../architecture/review-2026-09.md):
before any module moves, every failure has to be observable and every
answer has to be true.

The rule, in one line: **a failure is observable, the caller receives an
accurate outcome, and continuing leaves valid state.** A boundary may catch
any exception, as long as it reports what it caught. What it may not do is
turn "no implementation", "implementation not running" and "implementation
raised" into the same successful-looking value.

## Seams and their guarantees

| Seam | Implementation registered by | Contract | Verified at |
| --- | --- | --- | --- |
| `LemonCore.RouterBridge` (`:router`) | `LemonRouter.Application` | `LemonCore.RouterBridge.Router` | `configure/1`, via `LemonCore.Contract.validate/2` |
| `LemonCore.RouterBridge` (`:run_orchestrator`) | `LemonRouter.Application` | `LemonCore.RouterBridge.RunOrchestrator` | `configure/1` |
| `LemonCore.EventBridge` | `LemonControlPlane.Application` | `LemonCore.EventBridge.Fanout` | `configure/1` |
| `LemonCore.EngineInfoBridge` | `LemonGateway.Application` | `LemonCore.EngineInfoBridge.TransportRegistry` | `configure/1` |
| `LemonCore.EngineRuntime` | `config :lemon_router, :engine_runtime` | `LemonCore.EngineRuntime` | `LemonRouter.Application` at boot, `LemonRouter.RunProcess` at init |
| `LemonGateway.Executor` | `config :lemon_gateway, :executor` | `LemonGateway.Executor` | `LemonGateway.Application` at boot |

Validation means: the module is loadable and exports every required callback.
Once validated, call sites call the implementation directly. No call site
guards a validated seam with `function_exported?/3`, and no call site falls
back to a second path (a dynamic module atom, a different function name)
when the first is missing: a missing implementation is `{:error,
:unavailable}` and nothing else.

## Outcomes a caller can receive

Every bridge function answers one of exactly these, and each means one thing:

| Answer | Meaning | Logged |
| --- | --- | --- |
| `:ok` / `{:ok, value}` | The implementation accepted the request. For asynchronous work (submit, cancel) this means *delivered*, not *finished*. | no |
| `{:error, :unavailable}` | No implementation is registered, or the registered one has no running process (the call exited, timed out, or the process died mid-call). The work was not accepted; the caller's only decision is whether to retry. | warning, with the exit reason |
| `{:error, %ExceptionStruct{}}` | The implementation was reached and raised. This is a bug, not an availability problem. | error, with the stacktrace |
| `{:error, {:unexpected_answer, term}}` | The implementation returned something outside its contract. Also a bug. | error |

Query functions (`session_busy?/1`, `active_run/1`, `list_active_sessions/0`)
answer `{:error, :unavailable}` like everything else. They used to answer a
soft value (`false`, `:none`, `[]`) for an unreachable router, which let a
channel adapter start work it would otherwise have queued and hid the
outage. Deciding what an unknown router state means is the caller's job, and
the caller says so where it decides.

## Run lifecycle promises

The promises the router, the execution runtime and the executor make to each
other, gathered from their contracts and the code that keeps them:

- **Submit is asynchronous.** `EngineRuntime.submit_execution/1` returning
  `:ok` means accepted. Results arrive as `LemonCore.Bus` events under the
  run id. A rejection is retried with backoff and never dropped; a
  permanently invalid command must be completed with an error event by the
  runtime rather than rejected forever.
- **Unavailability parks, misconfiguration is loud.** A runtime whose
  `available?/0` is false, or none configured at all, parks the run with
  backoff; a router-only node boots and queues. A *configured* runtime that
  fails validation is a configuration bug: it is logged at error level at
  boot and treated as unavailable, never silently substituted with
  `GenServer.whereis/1` on the module name.
- **Cancel is total, idempotent, best-effort and asynchronous.** Cancelling
  a finished, unknown or never-submitted run is `:ok`. `:ok` means the
  request was delivered. What `:ok` no longer means is "there was nothing to
  deliver it to": that is `{:error, :unavailable}`.
- **Completion is exactly once per run.** Every accepted run ends in one
  terminal bus event, from the runtime on normal completion or from the
  router's watchdog and process monitoring when the runtime goes away.
- **Runtime loss is noticed.** The router monitors the pid returned by
  `run_pid/1`; a runtime that returns a pid for a run it is not executing
  produces a spurious `:DOWN`, so `nil` is the answer for unknown, finished
  or queued runs.
- **Persistence failures are answered, not hidden.** `LemonCore.Store`
  writes the backend before the read cache and only then answers, so a read
  after a successful write cannot observe the previous value and a failed
  write never looks like a success. Asynchronous writes (`put_async/4`,
  `update_async/5`, and so `LemonCore.RunStore.append_event/3`) may lag a
  read by one message; `ping/1` is the barrier. See
  [owned-storage.md](owned-storage.md) for who owns what a table means.

## How this is kept true

- `LemonCore.Contract.validate/2` is the single place the platform uses
  `function_exported?/3` on a configured seam.
- `LemonCore.Quality.RatchetCheck` counts reflection sites and dynamic module
  atoms in `lib/`; both may only go down.
- `LemonCore.Quality.ArchitectureRulesCheck` keeps the composition in
  `config/config.exs`: a lower app never names a higher app's module in
  code.
- [Failure Handling](failure-handling.md) is the policy for every other
  `rescue`: a caught failure is logged with its stacktrace through
  `LemonCore.Failure`, the caller gets an accurate outcome, and the
  `silent_rescues` ratchet counts the clauses that still discard the
  exception.
