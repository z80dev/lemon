# LemonGateway contributor guide

Gateway owns execution slots, launch isolation, native run lifecycle, cancellation
and resume. Router owns collect/follow-up/steer/interrupt semantics. Channels owns
messaging adapters; gateway-native SMS/voice/webhook ingress remains opt-in through
`:gateway_ingress_enabled`. See [README](README.md).

## Executor and lifecycle

- Gateway has one configured singleton executor, `CodingAgent.Executor`, validated
  by `LemonGateway.Executor`. Native runs carry fixed `engine: "lemon"` provenance;
  subagent identity never selects or replaces gateway execution.
- Do not restore engine registries, selectable/custom engines, vendor CLI runners
  or engine-selection config. Add model providers in `lemon_ai`, native tools in
  `coding_agent`, and delegation through the existing `task`/`agent` tools.
- The public submission boundary is
  `LemonGateway.Runtime.submit_execution(%LemonCore.ExecutionCommand{})`.
  Gateway constructs its private `ExecutionRequest`; consumers do not.
- `Scheduler` grants slots for the router-supplied conversation key.
  `ThreadWorker` only launches runs; run-owned unique Registry names provide
  session isolation, with `EngineLock` retaining FIFO admission, not a product queue.
- Slot requests carry a generation token. Timeout retries cancel the prior
  generation before requesting again. Bounded failed launch attempts produce
  one structured terminal completion and advance the worker.
- A live lock owner is never displaced solely because it is old. Transfer on
  explicit release or confirmed owner death.
- Completion stores native resume state, releases lock/slot and notifies bus
  observers. Cancel by exact run ID; top-level resume accepts native tokens only.

## Ingress and idempotency

Prefer `lemon_channels` for new messaging platforms. Gateway ingress submits
`LemonCore.RunRequest` through `RouterBridge`, with stable session and run IDs.
Disabled ingress returns `:ignore` from startup; use shared binding resolution.

Webhook mutation boundaries are deliberately conservative:

- Reserve idempotency keys atomically before submission. Hash the caller's key
  with integration identity before any durable key, receipt or router request;
  reject blank/non-binary keys before hashing.
- `:outcome_unknown` may already have executed. Acknowledge HTTP delivery with a
  bounded uncertain receipt, fixed run ID and `retry_safe: false`, not a
  retryable 5xx. Mutation exceptions/exits are unknown, not definite rejection.
- Reservation/replay/receipt-store failures fail closed without claiming
  acceptance. Pending reservation and missing exact response are different
  states; never replay a generic success where the original response is unknown.
- Legacy raw-key migration first durably writes the hashed fence and exact
  response, then conditionally deletes raw records. Partial/concurrent migration
  cannot authorize replay. Legacy pending rows without run IDs remain ambiguous
  fences, not invented execution identities.
- Expiry removes response snapshots before primary fences on ordered backends;
  SQLite removes durable pairs transactionally. Failed cleanup neither permits
  replay nor advances the sweep watermark.

## Operations

For stuck execution, inspect scheduler in-flight slots, lock waiters and live
run/worker children. For an unready executor, call
`LemonGateway.Executor.validate_configured/0`, not an engine registry lookup.
Resume state lives in `LemonCore.ChatStateStore` and the native session.

```elixir
LemonGateway.Scheduler.stats()
:sys.get_state(LemonGateway.EngineLock)
DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)
DynamicSupervisor.which_children(LemonGateway.RunSupervisor)
```

Bus events use `run:<run_id>`. `meta.notify_pid` may receive
`{:lemon_gateway_run_completed, request, completed}`. Keep these runtime contracts
separate from user-facing channel rendering.

## Verification

From the umbrella root: `mix test apps/lemon_gateway/test`.
Tests stopping runtime applications restore exactly the original running set
with `Application.ensure_all_started/1`. Gateway transport tests may own gateway/
channels but must not stop unrelated consumers such as the control plane.
Exercise slot timeouts, owner death, cancellation races, restart and replay-store
failure, not just happy-path submission.
